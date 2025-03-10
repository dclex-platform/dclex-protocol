// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {DclexPool} from "../src/DclexPool.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployDclexPool is Script {
    function run(
        IStock stockToken,
        HelperConfig helperConfig
    ) external returns (DclexPool) {
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        string memory stockSymbol = stockToken.symbol();
        bytes32 stockPriceFeedId = helperConfig.getPriceFeedId(stockSymbol);
        bytes32 usdcPriceFeedId = helperConfig.getPriceFeedId("USDC");
        vm.startBroadcast();
        DclexPool dclexPool = new DclexPool(
            stockToken,
            config.usdcToken,
            config.pyth,
            stockPriceFeedId,
            usdcPriceFeedId,
            config.admin
        );
        vm.stopBroadcast();
        return dclexPool;
    }
}
