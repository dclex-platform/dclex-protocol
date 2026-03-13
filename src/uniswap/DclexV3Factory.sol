// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {Security} from "../base/Security.sol";

/// @title Gated UniswapV3Factory with access control
/// @notice Extends UniswapV3Factory to restrict pool creation to authorized roles
/// @dev The inherited setOwner() and enableFeeAmount() functions use the original owner-based
///      access control from UniswapV3Factory (not role-based) since they are not virtual.
///      In production, set owner to address(0) after initial setup to disable these functions,
///      or ensure the owner address is controlled by the same governance as MASTER_ADMIN_ROLE.
contract DclexV3Factory is UniswapV3Factory, Security {

    /// @notice Creates a pool for the given two tokens and fee, restricted to DEFAULT_ADMIN_ROLE
    /// @param tokenA One of the two tokens in the desired pool
    /// @param tokenB The other of the two tokens in the desired pool
    /// @param fee The desired fee for the pool
    /// @return pool The address of the newly created pool
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    )
        public
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (address pool)
    {
        return super.createPool(tokenA, tokenB, fee);
    }
}
