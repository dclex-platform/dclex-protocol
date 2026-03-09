// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPriceOracle} from "./IPriceOracle.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract FIOracle is IPriceOracle, AccessControl {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    error InvalidSignature();
    error InvalidUpdateData();
    error FuturePublishTime();

    address public trustedSigner;
    mapping(bytes32 => Price) private priceFeeds;

    event TrustedSignerUpdated(address newSigner);

    constructor(address _trustedSigner, address admin) {
        trustedSigner = _trustedSigner;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setTrustedSigner(
        address _trustedSigner
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trustedSigner = _trustedSigner;
        emit TrustedSignerUpdated(_trustedSigner);
    }

    /// @notice Updates price feeds with signed data from the trusted signer.
    /// @param updateData Each element: abi.encodePacked(feedId, price, expo, publishTime, v, r, s)
    ///        feedId: bytes32 (32 bytes)
    ///        price: int64 (8 bytes)
    ///        expo: int32 (4 bytes)
    ///        publishTime: uint64 (8 bytes)
    ///        v: uint8 (1 byte)
    ///        r: bytes32 (32 bytes)
    ///        s: bytes32 (32 bytes)
    ///        Total: 117 bytes
    function updatePriceFeeds(
        bytes[] calldata updateData
    ) external payable override {
        for (uint256 i = 0; i < updateData.length; ++i) {
            _updateSingleFeed(updateData[i]);
        }
    }

    function getPriceNoOlderThan(
        bytes32 id,
        uint256 age
    ) external view override returns (Price memory) {
        Price memory p = priceFeeds[id];
        if (p.publishTime == 0) {
            revert PriceFeedNotFound();
        }
        if (block.timestamp - p.publishTime > age) {
            revert StalePrice();
        }
        return p;
    }

    function getUpdateFee(
        bytes[] calldata
    ) external pure override returns (uint256) {
        return 0;
    }

    function _updateSingleFeed(bytes calldata data) private {
        if (data.length != 117) {
            revert InvalidUpdateData();
        }

        bytes32 feedId = bytes32(data[0:32]);
        int64 price = int64(uint64(bytes8(data[32:40])));
        int32 expo = int32(uint32(bytes4(data[40:44])));
        uint64 publishTime = uint64(bytes8(data[44:52]));

        // Reject future timestamps to prevent underflow in getPriceNoOlderThan
        if (publishTime > block.timestamp) {
            revert FuturePublishTime();
        }

        // Only accept newer prices
        if (publishTime <= priceFeeds[feedId].publishTime) {
            return;
        }

        // Verify signature
        bytes32 messageHash = keccak256(
            abi.encodePacked(feedId, price, expo, publishTime)
        );
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();

        uint8 v = uint8(data[52]);
        bytes32 r = bytes32(data[53:85]);
        bytes32 s = bytes32(data[85:117]);

        address recovered = ethSignedHash.recover(v, r, s);
        if (recovered != trustedSigner) {
            revert InvalidSignature();
        }

        priceFeeds[feedId] = Price(price, expo, publishTime);
    }
}
