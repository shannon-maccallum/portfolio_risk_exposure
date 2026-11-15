// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ExposureOracle} from "./ExposureOracle.sol";
import {MockExchange} from "./MockExchange.sol";
import {FundFactory} from "./FundFactory.sol";

/// @notice Deploys the whole system in one transaction (one wallet approval):
/// the Exposure Oracle (owned by the deployer), the mock exchange with test dollars and
/// simulated stocks, and the fund factory.
contract Platform {
    ExposureOracle public immutable oracle;
    MockExchange public immutable exchange;
    FundFactory public immutable factory;

    constructor(string[] memory themes, string[] memory stockSymbols) {
        oracle = new ExposureOracle(msg.sender, themes);
        exchange = new MockExchange(oracle, stockSymbols);
        factory = new FundFactory(oracle, exchange);
    }

    function stocks() external view returns (address[] memory) {
        return exchange.allStocks();
    }
}
