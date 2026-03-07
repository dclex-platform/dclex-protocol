// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {FIOracle} from "../src/FIOracle.sol";

/// @notice Deploys FIOracle with a trusted signer and admin.
///         Usage: FOUNDRY_PROFILE=default forge script script/DeployFIOracle.s.sol --broadcast
contract DeployFIOracle is Script {
    function run(
        address trustedSigner,
        address admin
    ) external returns (FIOracle) {
        vm.startBroadcast();
        FIOracle oracle = new FIOracle(trustedSigner, admin);
        vm.stopBroadcast();
        console.log("FIOracle deployed at:", address(oracle));
        return oracle;
    }
}
