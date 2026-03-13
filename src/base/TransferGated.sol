// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IDID} from "dclex-mint/contracts/interfaces/IDID.sol";
import {InvalidDID} from "dclex-mint/contracts/libs/Model.sol";

/// @title TransferGated
/// @notice Abstract contract providing DID-based transfer gating for tokens
/// @dev Inherit this contract and implement _getDID() to enable transfer verification
abstract contract TransferGated {

    /// @notice Returns the DID contract used for transfer verification
    /// @return The IDID contract instance
    function _getDID() internal view virtual returns (IDID);

    /// @notice Modifier that verifies both sender and receiver have valid DIDs
    /// @param from The address sending tokens
    /// @param to The address receiving tokens
    /// @param amount The amount being transferred (used for interface compatibility)
    modifier checkTransferActors(address from, address to, uint256 amount) {
        if (!_getDID().verifyTransfer(from, to, amount)) {
            revert InvalidDID();
        }
        _;
    }
}
