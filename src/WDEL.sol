// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Wrapped DEL (WDEL)
/// @notice An ERC20 wrapper for the native DEL token
/// @dev Deposit native DEL to receive WDEL, withdraw WDEL to receive native DEL
contract WDEL is ERC20 {
    error WDEL__NativeTransferFailed();

    event Deposit(address indexed account, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    constructor() ERC20("Wrapped DEL", "WDEL") {}

    /// @notice Deposit native DEL to receive WDEL
    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Withdraw WDEL to receive native DEL
    /// @param amount The amount of WDEL to withdraw
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert WDEL__NativeTransferFailed();
        emit Withdrawal(msg.sender, amount);
    }

    /// @notice Receive native DEL and mint WDEL
    receive() external payable {
        deposit();
    }
}
