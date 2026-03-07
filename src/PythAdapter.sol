// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPriceOracle} from "./IPriceOracle.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @notice Wraps an existing IPyth contract to implement IPriceOracle,
///         enabling backward compatibility with Pyth-based deployments.
contract PythAdapter is IPriceOracle {
    IPyth public immutable pyth;

    constructor(IPyth _pyth) {
        pyth = _pyth;
    }

    function updatePriceFeeds(
        bytes[] calldata updateData
    ) external payable override {
        pyth.updatePriceFeeds{value: msg.value}(updateData);
    }

    function getPriceNoOlderThan(
        bytes32 id,
        uint256 age
    ) external view override returns (Price memory) {
        PythStructs.Price memory p = pyth.getPriceNoOlderThan(id, age);
        return Price(p.price, p.expo, uint64(p.publishTime));
    }

    function getUpdateFee(
        bytes[] calldata updateData
    ) external view override returns (uint256) {
        return pyth.getUpdateFee(updateData);
    }
}
