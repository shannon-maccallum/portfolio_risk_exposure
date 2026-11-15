// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Public record of each stock's price and its exposure to each theme (AI, Oil, ...).
/// Exposure is a score from 0 to 100% (stored in basis points, 10000 = 100%), and the
/// tier (None / Low / Medium / High) is derived from the score on-chain so it can't be fudged.
/// One wallet (the owner) posts the data. In production this would be several independent signers.
contract ExposureOracle {
    uint16 public constant MEDIUM_BPS = 1500; // 15% or more is Medium
    uint16 public constant HIGH_BPS = 4000; // 40% or more is High

    address public owner;
    bytes32[] public themeIds;
    mapping(bytes32 => string) public themeName;
    mapping(bytes32 => bool) public isTheme;

    mapping(address => uint256) public priceOf; // US dollars per token, 18 decimals
    mapping(address => uint64) public updatedAt;
    mapping(address => mapping(bytes32 => uint16)) public scoreBps;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PriceUpdated(address indexed token, uint256 price);
    event ScoreUpdated(address indexed token, bytes32 indexed theme, uint16 scoreBps, uint8 tier);

    error NotOwner();
    error LengthMismatch();
    error UnknownTheme(bytes32 theme);
    error ScoreTooHigh(uint16 scoreBps);
    error ZeroPrice(address token);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, string[] memory names) {
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        for (uint256 i = 0; i < names.length; i++) {
            bytes32 id = themeIdOf(names[i]);
            if (!isTheme[id]) {
                isTheme[id] = true;
                themeName[id] = names[i];
                themeIds.push(id);
            }
        }
    }

    function themeIdOf(string memory name) public pure returns (bytes32) {
        return keccak256(bytes(name));
    }

    function themeCount() external view returns (uint256) {
        return themeIds.length;
    }

    function allThemes() external view returns (bytes32[] memory) {
        return themeIds;
    }

    /// @notice Post prices and scores for many tokens at once.
    /// `scores` is flattened row by row: scores[i * themes.length + j] is token i, theme j.
    function post(address[] calldata tokens, uint256[] calldata prices, bytes32[] calldata themes, uint16[] calldata scores)
        external
        onlyOwner
    {
        if (tokens.length != prices.length || scores.length != tokens.length * themes.length) revert LengthMismatch();
        for (uint256 i = 0; i < tokens.length; i++) {
            _setPrice(tokens[i], prices[i]);
            for (uint256 j = 0; j < themes.length; j++) {
                _setScore(tokens[i], themes[j], scores[i * themes.length + j]);
            }
        }
    }

    /// @notice Update one score, e.g. after a new filing changes a company's business mix.
    function setScore(address token, bytes32 theme, uint16 bps) external onlyOwner {
        _setScore(token, theme, bps);
    }

    function setPrice(address token, uint256 price) external onlyOwner {
        _setPrice(token, price);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function tierOf(address token, bytes32 theme) public view returns (uint8) {
        return tierForScore(scoreBps[token][theme]);
    }

    function tierForScore(uint16 bps) public pure returns (uint8) {
        if (bps >= HIGH_BPS) return 3;
        if (bps >= MEDIUM_BPS) return 2;
        if (bps > 0) return 1;
        return 0;
    }

    function tierName(uint8 tier) public pure returns (string memory) {
        if (tier == 3) return "High";
        if (tier == 2) return "Medium";
        if (tier == 1) return "Low";
        return "None";
    }

    function _setPrice(address token, uint256 price) internal {
        if (price == 0) revert ZeroPrice(token);
        priceOf[token] = price;
        updatedAt[token] = uint64(block.timestamp);
        emit PriceUpdated(token, price);
    }

    function _setScore(address token, bytes32 theme, uint16 bps) internal {
        if (!isTheme[theme]) revert UnknownTheme(theme);
        if (bps > 10000) revert ScoreTooHigh(bps);
        scoreBps[token][theme] = bps;
        emit ScoreUpdated(token, theme, bps, tierForScore(bps));
    }
}
