// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Master admin role with full control
bytes32 constant MASTER_ADMIN_ROLE = keccak256("MASTER_ADMIN_ROLE");

/// @title Abstract Security contract with admin roles, reentrancy guard and pausable interface
abstract contract Security is AccessControl, Pausable, ReentrancyGuard {
    constructor() {
        _grantRole(MASTER_ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setRoleAdmin(DEFAULT_ADMIN_ROLE, MASTER_ADMIN_ROLE);
        _setRoleAdmin(MASTER_ADMIN_ROLE, MASTER_ADMIN_ROLE);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
