// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USDCMock} from "../test/USDCMock.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

contract HelperConfig is Script {
    error HelperConfig__InvalidChainId();

    struct NetworkConfig {
        address admin;
        IERC20 usdcToken;
        IPyth pyth;
    }

    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant LOCAL_CHAIN_ID = 31337;
    string private constant PRICE_FEED_IDS_FILE = "pythPriceFeedIds.json";
    mapping(string => bytes32) public priceFeedIds;
    NetworkConfig public localNetworkConfig;

    constructor() {
        string memory file = vm.readFile(PRICE_FEED_IDS_FILE);
        string[] memory symbols = vm.parseJsonKeys(file, "$");
        for (uint256 i = 0; i < symbols.length; i++) {
            priceFeedIds[symbols[i]] = vm.parseJsonBytes32(
                file,
                string.concat("$.", symbols[i])
            );
        }
    }

    function getConfig() public returns (NetworkConfig memory) {
        if (block.chainid == LOCAL_CHAIN_ID) {
            return getLocalConfig();
        } else if (block.chainid == ETH_SEPOLIA_CHAIN_ID) {
            return getSepoliaConfig();
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    function getSepoliaConfig() public pure returns (NetworkConfig memory) {
        return
            NetworkConfig({
                admin: 0x971b5a2872ec17EeDDED9fc4dd691D8B33B97031,
                usdcToken: IERC20(0x66e6530B7de904B4e83392a9fB2D9d650aE1f060),
                pyth: IPyth(0xDd24F84d36BF92C65F92307595335bdFab5Bbd21)
            });
    }

    function getLocalConfig() public returns (NetworkConfig memory) {
        if (address(localNetworkConfig.pyth) != address(0)) {
            return localNetworkConfig;
        }
        IERC20 usdcToken = new USDCMock("USDC", "USD Coin");
        localNetworkConfig = NetworkConfig({
            admin: makeAddr("pool_admin"),
            usdcToken: usdcToken,
            pyth: new MockPyth(60, 1)
        });
        return localNetworkConfig;
    }

    function getPriceFeedId(
        string memory symbol
    ) public view returns (bytes32) {
        return priceFeedIds[symbol];
    }
}
