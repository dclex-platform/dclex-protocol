// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {NonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/NonfungiblePositionManager.sol";
import {TransferGated} from "../base/TransferGated.sol";
import {IDID} from "dclex-mint/contracts/interfaces/IDID.sol";
import {InvalidDID} from "dclex-mint/contracts/libs/Model.sol";

/// @title DID-Gated Nonfungible Position Manager
/// @notice Extends Uniswap V3 NonfungiblePositionManager with DID verification for transfers
/// @dev NFT positions can only be transferred between addresses with valid DIDs
contract DclexPositionManager is NonfungiblePositionManager, TransferGated {
    IDID private immutable _did;

    constructor(
        address factory_,
        address weth9_,
        address tokenDescriptor_,
        IDID did_
    ) NonfungiblePositionManager(factory_, weth9_, tokenDescriptor_) {
        _did = did_;
    }

    /// @notice Returns the DID contract used for transfer verification
    function _getDID() internal view override returns (IDID) {
        return _did;
    }

    /// @notice Returns the DID contract address
    function DID() external view returns (IDID) {
        return _did;
    }

    /// @dev Override _update to add DID verification for transfers
    /// @param to The address receiving the token
    /// @param tokenId The token being transferred
    /// @param auth The authorized address for the operation
    /// @return The previous owner of the token
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Skip DID check for mints (from == address(0)) and burns (to == address(0))
        if (from != address(0) && to != address(0)) {
            // Use amount=1 for NFT transfers since each transfer is exactly 1 token
            if (!_getDID().verifyTransfer(from, to, 1)) {
                revert InvalidDID();
            }
        }

        return super._update(to, tokenId, auth);
    }
}
