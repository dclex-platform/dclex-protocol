// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythUtils.sol";

contract DclexPythMock {
    MockPyth private mockPyth;

    constructor() {
        mockPyth = new MockPyth(60, 1);
    }

    function updatePrice(bytes32 priceFeedId, uint256 price) external {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = getUpdatePriceData(priceFeedId, price);
        uint256 value = mockPyth.getUpdateFee(updateData);
        mockPyth.updatePriceFeeds{value: value}(updateData);
    }

    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint256) {
        return mockPyth.getUpdateFee(updateData);
    }

    function getUpdatePriceData(
        bytes32 priceFeedId,
        uint256 price
    ) public view returns (bytes memory) {
        return
            mockPyth.createPriceFeedUpdateData(
                priceFeedId,
                int64(uint64(price / 1e10)),
                10,
                -8,
                int64(uint64(price)),
                10,
                uint64(block.timestamp),
                uint64(block.timestamp)
            );
    }

    function getPrice(bytes32 priceFeedId) external view returns (uint256) {
        PythStructs.Price memory pythPrice = mockPyth.getPriceNoOlderThan(
            priceFeedId,
            60
        );
        return PythUtils.convertToUint(pythPrice.price, pythPrice.expo, 18);
    }

    function getPyth() external view returns (IPyth) {
        return mockPyth;
    }
}
