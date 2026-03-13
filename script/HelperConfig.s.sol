// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPriceOracle} from "../src/IPriceOracle.sol";
import {PythAdapter} from "../src/PythAdapter.sol";
import {FIOracle} from "../src/FIOracle.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USDCMock} from "../test/mocks/USDCMock.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

contract HelperConfig is Script {
    error HelperConfig__InvalidChainId();

    struct NetworkConfig {
        address admin;
        IERC20 usdcToken;
        IPriceOracle oracle;
    }

    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant PRIMELTA_DEV_CHAIN_ID = 2028;
    string private constant PRICE_FEED_IDS_FILE = "pythPriceFeedIds.json";
    mapping(string => bytes32) public priceFeedIds;
    NetworkConfig public localNetworkConfig;
    NetworkConfig public primeltaDevNetworkConfig;

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
        } else if (block.chainid == PRIMELTA_DEV_CHAIN_ID) {
            return getPrimeltaDevConfig();
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    function getSepoliaConfig() public returns (NetworkConfig memory) {
        vm.startBroadcast();
        PythAdapter adapter = new PythAdapter(
            IPyth(0xDd24F84d36BF92C65F92307595335bdFab5Bbd21)
        );
        vm.stopBroadcast();
        return
            NetworkConfig({
                admin: 0x971b5a2872ec17EeDDED9fc4dd691D8B33B97031,
                usdcToken: IERC20(0x66e6530B7de904B4e83392a9fB2D9d650aE1f060),
                oracle: IPriceOracle(address(adapter))
            });
    }

    function getLocalConfig() public returns (NetworkConfig memory) {
        if (address(localNetworkConfig.oracle) != address(0)) {
            return localNetworkConfig;
        }
        vm.startBroadcast();
        MockPyth mockPyth = new MockPyth(60, 1);
        PythAdapter adapter = new PythAdapter(IPyth(address(mockPyth)));
        IERC20 usdcToken = new USDCMock("USDC", "USD Coin");
        vm.stopBroadcast();
        localNetworkConfig = NetworkConfig({
            admin: makeAddr("pool_admin"),
            usdcToken: usdcToken,
            oracle: IPriceOracle(address(adapter))
        });
        return localNetworkConfig;
    }

    function getPrimeltaDevConfig() public returns (NetworkConfig memory) {
        if (address(primeltaDevNetworkConfig.oracle) != address(0)) {
            return primeltaDevNetworkConfig;
        }
        vm.startBroadcast();
        // Use FIOracle for primelta-dev with backend signer as trusted signer
        FIOracle fiOracle = new FIOracle(
            0x971b5a2872ec17EeDDED9fc4dd691D8B33B97031, // backend signer
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8 // admin
        );
        vm.stopBroadcast();
        primeltaDevNetworkConfig = NetworkConfig({
            admin: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            usdcToken: IERC20(0x951c4871D16d953a3Fd64c17a756B1aA95D63E58),
            oracle: IPriceOracle(address(fiOracle))
        });
        return primeltaDevNetworkConfig;
    }

    function getPriceFeedId(
        string memory symbol
    ) public view returns (bytes32) {
        return priceFeedIds[symbol];
    }
}
