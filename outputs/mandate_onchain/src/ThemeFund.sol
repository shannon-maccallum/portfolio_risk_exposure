// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ExposureOracle} from "./ExposureOracle.sol";
import {MockExchange} from "./MockExchange.sol";
import {MockToken} from "./MockToken.sol";

/// @notice A themed fund. The token (e.g. $AIXO) is a share of the basket it holds.
///
/// The fund's rules ("AI at least 60%", "no stock with High oil exposure") are fixed at launch
/// and can never be changed. Every basket is checked against the Exposure Oracle:
///   - at launch,
///   - whenever the creator proposes a new basket (a rejected proposal is recorded, not hidden),
///   - whenever anyone calls enforce(). If a holding has drifted past a limit, enforce() sells it
///     and pays the caller a small bounty, so strangers are paid to keep the fund honest.
/// Every check is counted on-chain (checksPassed / checksFailed): the fund's "rule receipts".
///
/// Deployed as cheap clones by FundFactory, so it uses initialize() instead of a constructor.
contract ThemeFund is ERC20 {
    struct Rule {
        bytes32 theme; // oracle theme id, e.g. keccak256("AI")
        uint16 minBps; // fund-level exposure floor, 10000 = 100%
        uint16 maxBps; // fund-level exposure ceiling
        uint8 maxTier; // highest tier any single holding may have: 0 None, 1 Low, 2 Medium, 3 High
    }

    uint256 public constant MAX_ASSETS = 10;
    uint256 public constant INITIAL_SHARE_PRICE = 10e18; // $10 per share at launch
    uint16 public constant BOUNTY_BPS = 50; // enforcer earns 0.5% of the value sold

    string private _fundName;
    string private _fundSymbol;
    bool public initialized;

    address public creator;
    ExposureOracle public oracle;
    MockExchange public exchange;
    MockToken public usd;

    address[] internal _assets;
    uint16[] internal _weights;
    Rule[] internal _rules;

    uint256 public checksPassed;
    uint256 public checksFailed;
    string public lastFailReason; // shown in the app without needing to search old logs

    event Launched(address indexed creator, string name, string symbol);
    event Deposited(address indexed user, uint256 usdIn, uint256 sharesOut);
    event Redeemed(address indexed user, uint256 sharesIn, uint256 usdOut);
    event BasketChanged(address[] assets, uint16[] weights);
    event CheckPassed(string kind, uint256 checkNumber);
    event CheckFailed(string kind, string reason, uint256 checkNumber);
    event Enforced(address indexed enforcer, address indexed asset, string reason, uint256 usdSold, uint256 bounty);

    error AlreadyInitialized();
    error NotCreator();
    error ZeroAmount();
    error InsufficientShares();
    error InvalidBasket(string reason);
    error InvalidRule(uint256 index);

    constructor() ERC20("", "") {
        initialized = true; // the template itself can never be used as a fund
    }

    // ------------------------------------------------------------------ setup

    function initialize(
        address creator_,
        string calldata name_,
        string calldata symbol_,
        ExposureOracle oracle_,
        MockExchange exchange_,
        address[] calldata assets_,
        uint16[] calldata weights_,
        Rule[] calldata rules_
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        creator = creator_;
        _fundName = name_;
        _fundSymbol = symbol_;
        oracle = oracle_;
        exchange = exchange_;
        usd = exchange_.usd();

        for (uint256 i = 0; i < rules_.length; i++) {
            Rule calldata r = rules_[i];
            if (!oracle_.isTheme(r.theme) || r.minBps > r.maxBps || r.maxBps > 10000 || r.maxTier > 3) {
                revert InvalidRule(i);
            }
            _rules.push(r);
        }

        (bool ok, string memory reason) = checkBasket(assets_, weights_);
        if (!ok) revert InvalidBasket(reason);
        _assets = assets_;
        _weights = weights_;
        _recordPass("launch");
        emit Launched(creator_, name_, symbol_);
        emit BasketChanged(assets_, weights_);
    }

    function name() public view override returns (string memory) {
        return _fundName;
    }

    function symbol() public view override returns (string memory) {
        return _fundSymbol;
    }

    // ------------------------------------------------------------------ views

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function weights() external view returns (uint16[] memory) {
        return _weights;
    }

    function rules() external view returns (Rule[] memory) {
        return _rules;
    }

    /// @notice Total value of everything the fund holds, in test dollars (18 decimals).
    function nav() public view returns (uint256 total) {
        total = usd.balanceOf(address(this));
        for (uint256 i = 0; i < _assets.length; i++) {
            total += (IERC20Metadata(_assets[i]).balanceOf(address(this)) * oracle.priceOf(_assets[i])) / 1e18;
        }
    }

    /// @notice Price of one fund token = total value / number of tokens (same math as an ETF's NAV).
    function sharePrice() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return INITIAL_SHARE_PRICE;
        return (nav() * 1e18) / supply;
    }

    /// @notice The fund's current exposure to a theme, weighted by its target weights (bps).
    function exposureOf(bytes32 theme) public view returns (uint256) {
        return _exposure(_assets, _weights, theme);
    }

    /// @notice Would this basket pass the fund's rules? Returns a plain-English reason if not.
    /// Free to call (no transaction), so the app can preview a change before sending it.
    function checkBasket(address[] memory a, uint16[] memory w) public view returns (bool ok, string memory reason) {
        if (a.length == 0) return (false, "Basket is empty");
        if (a.length != w.length) return (false, "Assets and weights differ in length");
        if (a.length > MAX_ASSETS) return (false, "Too many assets (max 10)");

        uint256 sum;
        for (uint256 i = 0; i < a.length; i++) {
            if (oracle.priceOf(a[i]) == 0) return (false, "Asset has no oracle price");
            if (w[i] == 0) return (false, string.concat("Zero weight for ", _sym(a[i])));
            for (uint256 j = 0; j < i; j++) {
                if (a[j] == a[i]) return (false, string.concat("Duplicate asset ", _sym(a[i])));
            }
            sum += w[i];
        }
        if (sum != 10000) return (false, "Weights must add up to 100%");

        // Per-holding limits first: the clearest message ("Oil: High (XOM)").
        for (uint256 r = 0; r < _rules.length; r++) {
            for (uint256 i = 0; i < a.length; i++) {
                uint8 tier = oracle.tierOf(a[i], _rules[r].theme);
                if (tier > _rules[r].maxTier) {
                    return (false, _tierReason(_rules[r].theme, tier, a[i]));
                }
            }
        }
        // Then fund-level floors and ceilings.
        for (uint256 r = 0; r < _rules.length; r++) {
            Rule memory rule = _rules[r];
            uint256 e = _exposure(a, w, rule.theme);
            string memory theme = oracle.themeName(rule.theme);
            if (e < rule.minBps) {
                return (false, string.concat(theme, " exposure ", _pct(e), " is below the ", _pct(rule.minBps), " minimum"));
            }
            if (e > rule.maxBps) {
                return (false, string.concat(theme, " exposure ", _pct(e), " is above the ", _pct(rule.maxBps), " maximum"));
            }
        }
        return (true, "");
    }

    // ------------------------------------------------------------------ investor actions

    /// @notice Put in test dollars, get fund tokens. Needs an approve() on test dollars first.
    function deposit(uint256 usdIn) external returns (uint256 shares) {
        if (usdIn == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        uint256 navBefore = nav();
        usd.transferFrom(msg.sender, address(this), usdIn);
        if (supply == 0 || navBefore == 0) {
            shares = (usdIn * 1e18) / INITIAL_SHARE_PRICE;
        } else {
            shares = (usdIn * supply) / navBefore;
        }
        if (shares == 0) revert ZeroAmount();
        _invest(usdIn, _assets, _weights);
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, usdIn, shares);
    }

    /// @notice Hand back fund tokens (they are burned), get your slice of the basket in test dollars.
    function redeem(uint256 shares) external returns (uint256 usdOut) {
        if (shares == 0) revert ZeroAmount();
        if (shares > balanceOf(msg.sender)) revert InsufficientShares();
        uint256 supply = totalSupply();
        usdOut = (usd.balanceOf(address(this)) * shares) / supply; // share of idle cash
        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 amt = (IERC20Metadata(_assets[i]).balanceOf(address(this)) * shares) / supply;
            if (amt > 0) usdOut += exchange.sell(_assets[i], amt);
        }
        _burn(msg.sender, shares);
        usd.transfer(msg.sender, usdOut);
        emit Redeemed(msg.sender, shares, usdOut);
    }

    // ------------------------------------------------------------------ rule enforcement

    /// @notice Creator proposes a new basket. If it breaks a rule, nothing changes and the
    /// rejection is recorded on-chain with its reason. Returns true if the basket was changed.
    function proposeBasket(address[] calldata a, uint16[] calldata w) external returns (bool) {
        if (msg.sender != creator) revert NotCreator();
        (bool ok, string memory reason) = checkBasket(a, w);
        if (!ok) {
            checksFailed++;
            lastFailReason = reason;
            emit CheckFailed("basket change", reason, checksPassed + checksFailed);
            return false;
        }
        // Sell everything, then buy the new basket.
        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 bal = IERC20Metadata(_assets[i]).balanceOf(address(this));
            if (bal > 0) exchange.sell(_assets[i], bal);
        }
        _assets = a;
        _weights = w;
        _invest(usd.balanceOf(address(this)), _assets, _weights);
        _recordPass("basket change");
        emit BasketChanged(a, w);
        return true;
    }

    /// @notice Anyone can call. If any holding now breaks a per-holding limit (for example its
    /// oil exposure has risen to High), it is sold, the money is reinvested in the remaining
    /// holdings, and the caller is paid a 0.5% bounty on the value sold. Returns the bounty.
    function enforce() external returns (uint256 bounty) {
        uint256 n = _assets.length;
        bool[] memory bad = new bool[](n);
        string[] memory why = new string[](n);
        uint256 badCount;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 r = 0; r < _rules.length; r++) {
                uint8 tier = oracle.tierOf(_assets[i], _rules[r].theme);
                if (tier > _rules[r].maxTier) {
                    bad[i] = true;
                    why[i] = _tierReason(_rules[r].theme, tier, _assets[i]);
                    badCount++;
                    break;
                }
            }
        }
        if (badCount == 0) {
            _recordPass("enforce");
            return 0;
        }

        // Sell the offenders and pay the enforcer.
        uint256 proceeds;
        for (uint256 i = 0; i < n; i++) {
            if (!bad[i]) continue;
            uint256 bal = IERC20Metadata(_assets[i]).balanceOf(address(this));
            uint256 sold = bal > 0 ? exchange.sell(_assets[i], bal) : 0;
            uint256 fee = (sold * BOUNTY_BPS) / 10000;
            proceeds += sold - fee;
            bounty += fee;
            emit Enforced(msg.sender, _assets[i], why[i], sold, fee);
        }

        // Keep the good holdings and scale their weights back up to 100%.
        uint256 keepCount = n - badCount;
        address[] memory keepA = new address[](keepCount);
        uint16[] memory keepW = new uint16[](keepCount);
        uint256 keptWeight;
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            if (bad[i]) continue;
            keepA[k] = _assets[i];
            keepW[k] = _weights[i];
            keptWeight += _weights[i];
            k++;
        }
        if (keepCount > 0) {
            uint256 assigned;
            for (uint256 i = 0; i < keepCount; i++) {
                if (i == keepCount - 1) {
                    keepW[i] = uint16(10000 - assigned);
                } else {
                    keepW[i] = uint16((uint256(keepW[i]) * 10000) / keptWeight);
                    assigned += keepW[i];
                }
            }
        }
        _assets = keepA;
        _weights = keepW;

        checksFailed++;
        lastFailReason = why[_firstTrue(bad)];
        emit CheckFailed("enforce", lastFailReason, checksPassed + checksFailed);
        emit BasketChanged(keepA, keepW);

        if (keepCount > 0) _invest(proceeds, keepA, keepW);
        if (bounty > 0) usd.transfer(msg.sender, bounty);
    }

    // ------------------------------------------------------------------ internals

    function _invest(uint256 amount, address[] memory a, uint16[] memory w) internal {
        for (uint256 i = 0; i < a.length; i++) {
            uint256 part = (amount * w[i]) / 10000;
            if (part > 0) exchange.buy(a[i], part);
        }
    }

    function _exposure(address[] memory a, uint16[] memory w, bytes32 theme) internal view returns (uint256 e) {
        for (uint256 i = 0; i < a.length; i++) {
            e += uint256(w[i]) * oracle.scoreBps(a[i], theme);
        }
        e /= 10000;
    }

    function _recordPass(string memory kind) internal {
        checksPassed++;
        emit CheckPassed(kind, checksPassed + checksFailed);
    }

    function _tierReason(bytes32 theme, uint8 tier, address asset) internal view returns (string memory) {
        return string.concat(oracle.themeName(theme), ": ", oracle.tierName(tier), " (", _sym(asset), ")");
    }

    function _sym(address token) internal view returns (string memory) {
        return IERC20Metadata(token).symbol();
    }

    /// @dev 5230 -> "52.3%"
    function _pct(uint256 bps) internal pure returns (string memory) {
        return string.concat(Strings.toString(bps / 100), ".", Strings.toString((bps % 100) / 10), "%");
    }

    function _firstTrue(bool[] memory b) internal pure returns (uint256) {
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i]) return i;
        }
        return 0;
    }
}
