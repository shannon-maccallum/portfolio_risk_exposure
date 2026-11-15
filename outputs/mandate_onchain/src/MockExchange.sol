// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockToken} from "./MockToken.sol";
import {ExposureOracle} from "./ExposureOracle.sol";

/// @notice Simulated stock market for testnet. Swaps test dollars for simulated stock tokens
/// at the oracle price, in both directions. In production this is replaced by trading real
/// tokenized stocks.
contract MockExchange {
    uint256 public constant FAUCET_AMOUNT = 10_000e18;

    ExposureOracle public immutable oracle;
    MockToken public immutable usd;
    address[] internal _stocks;
    mapping(address => bool) public isStock;
    mapping(string => address) public stockBySymbol;

    event StockListed(address indexed token, string symbol);
    event Bought(address indexed buyer, address indexed stock, uint256 usdIn, uint256 tokensOut);
    event Sold(address indexed seller, address indexed stock, uint256 tokensIn, uint256 usdOut);

    error NotAStock(address token);
    error NoPrice(address token);

    constructor(ExposureOracle oracle_, string[] memory symbols) {
        oracle = oracle_;
        usd = new MockToken("Test Dollar", "tUSD", address(this));
        for (uint256 i = 0; i < symbols.length; i++) {
            MockToken t = new MockToken(string.concat("Simulated ", symbols[i]), symbols[i], address(this));
            _stocks.push(address(t));
            isStock[address(t)] = true;
            stockBySymbol[symbols[i]] = address(t);
            emit StockListed(address(t), symbols[i]);
        }
    }

    function allStocks() external view returns (address[] memory) {
        return _stocks;
    }

    /// @notice Free test dollars for anyone, so people can try the funds.
    function faucet() external {
        usd.mint(msg.sender, FAUCET_AMOUNT);
    }

    function buy(address stock, uint256 usdIn) external returns (uint256 tokensOut) {
        uint256 price = _price(stock);
        usd.burn(msg.sender, usdIn);
        tokensOut = (usdIn * 1e18) / price;
        MockToken(stock).mint(msg.sender, tokensOut);
        emit Bought(msg.sender, stock, usdIn, tokensOut);
    }

    function sell(address stock, uint256 tokensIn) external returns (uint256 usdOut) {
        uint256 price = _price(stock);
        MockToken(stock).burn(msg.sender, tokensIn);
        usdOut = (tokensIn * price) / 1e18;
        usd.mint(msg.sender, usdOut);
        emit Sold(msg.sender, stock, tokensIn, usdOut);
    }

    function _price(address stock) internal view returns (uint256 price) {
        if (!isStock[stock]) revert NotAStock(stock);
        price = oracle.priceOf(stock);
        if (price == 0) revert NoPrice(stock);
    }
}
