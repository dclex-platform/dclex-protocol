// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {DclexPool} from "../src/DclexPool.sol";
import {IStock} from "dclex-mint/contracts/interfaces/IStock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployDclexPool is Script {
    uint256 private constant MAX_PRICE_STALENESS = 60;

    function run(
        IStock stockToken,
        HelperConfig helperConfig,
        uint256 maxPriceStaleness
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
            config.admin,
            maxPriceStaleness
        );
        vm.stopBroadcast();
        return dclexPool;
    }

    function run() external {
        address stock = (block.chainid == 11155111)
            ? 0x538d1094A35201D69e1Ac8c2dD42000C1CC0612E
            : 0x7fc1375aA5d360Ca90cc443B5c3d3919aA8B9208;
        this.run(
            IStock(address(stock)),
            new HelperConfig(),
            MAX_PRICE_STALENESS
        );
    }
}
