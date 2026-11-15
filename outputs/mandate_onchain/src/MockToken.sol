// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only token used for "test dollars" and simulated stocks (NVDA, XOM, ...).
/// Only the mock exchange (the minter) can create or destroy it.
contract MockToken is ERC20 {
    address public immutable minter;

    error NotMinter();

    constructor(string memory name_, string memory symbol_, address minter_) ERC20(name_, symbol_) {
        minter = minter_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _burn(from, amount);
    }
}
