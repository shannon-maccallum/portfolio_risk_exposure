// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ThemeFund} from "./ThemeFund.sol";
import {ExposureOracle} from "./ExposureOracle.sol";
import {MockExchange} from "./MockExchange.sol";

/// @notice One call launches a new themed fund with its basket, rules and token name.
/// Each fund is a lightweight copy (clone) of one template, so launching costs a fraction of
/// deploying a full contract: cheap enough for every user to have their own fund.
contract FundFactory {
    address public immutable implementation;
    ExposureOracle public immutable oracle;
    MockExchange public immutable exchange;

    address[] internal _funds;
    mapping(address => address[]) internal _fundsByCreator;

    event FundCreated(address indexed fund, address indexed creator, string name, string symbol);

    constructor(ExposureOracle oracle_, MockExchange exchange_) {
        oracle = oracle_;
        exchange = exchange_;
        implementation = address(new ThemeFund());
    }

    function createFund(
        string calldata name,
        string calldata symbol,
        address[] calldata assets,
        uint16[] calldata weights,
        ThemeFund.Rule[] calldata rules
    ) external returns (address fund) {
        fund = Clones.clone(implementation);
        ThemeFund(fund).initialize(msg.sender, name, symbol, oracle, exchange, assets, weights, rules);
        _funds.push(fund);
        _fundsByCreator[msg.sender].push(fund);
        emit FundCreated(fund, msg.sender, name, symbol);
    }

    function allFunds() external view returns (address[] memory) {
        return _funds;
    }

    function fundsBy(address creator) external view returns (address[] memory) {
        return _fundsByCreator[creator];
    }

    function fundCount() external view returns (uint256) {
        return _funds.length;
    }
}
