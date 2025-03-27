// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Stock} from "dclex-mint/contracts/dclex/Stock.sol";
import {USDCMock} from "dclex-mint/contracts/mocks/USDCMock.sol";
import {Factory} from "dclex-mint/contracts/dclex/Factory.sol";
import {TokenBuilder} from "dclex-mint/contracts/dclex/TokenBuilder.sol";
import {DigitalIdentity} from "dclex-mint/contracts/dclex/DigitalIdentity.sol";
import {SignatureUtils} from "dclex-mint/contracts/dclex/SignatureUtils.sol";
import {Vault} from "dclex-mint/contracts/dclex/Vault.sol";
import {Security} from "dclex-mint/contracts/dclex/Security.sol";
import {MASTER_ADMIN_ROLE} from "dclex-mint/contracts/libs/Model.sol";

contract DeployDclex is Script {
    struct DclexContracts {
        SignatureUtils signatureUtils;
        Factory stocksFactory;
        DigitalIdentity digitalIdentity;
        Vault vault;
        TokenBuilder tokenBuilder;
        USDCMock usdcMock;
    }

    USDCMock internal usdcMock;
    SignatureUtils internal signatureUtils;
    Factory internal stocksFactory;
    DigitalIdentity internal digitalIdentity;
    Vault internal vault;
    TokenBuilder internal tokenBuilder;

    function run(
        address standardAdmin,
        address masterAdmin
    ) external returns (DclexContracts memory) {
        vm.startBroadcast();
        usdcMock = new USDCMock("USDC Mock", "MUSDC");
        signatureUtils = new SignatureUtils();
        stocksFactory = new Factory(address(signatureUtils));
        digitalIdentity = new DigitalIdentity(
            "DCLEX Digital Identity",
            "DCLEX:DID",
            address(signatureUtils)
        );
        vault = new Vault(address(usdcMock), address(signatureUtils));
        tokenBuilder = new TokenBuilder(address(stocksFactory));

        stocksFactory.setTokenBuilder(address(tokenBuilder));
        stocksFactory.setDID(address(digitalIdentity));

        Security[3] memory securityContracts = [
            Security(stocksFactory),
            Security(digitalIdentity),
            Security(vault)
        ];
        for (uint256 i = 0; i < securityContracts.length; ++i) {
            Security securityContract = securityContracts[i];
            securityContract.grantRole(
                securityContract.DEFAULT_ADMIN_ROLE(),
                standardAdmin
            );
            securityContract.grantRole(MASTER_ADMIN_ROLE, masterAdmin);
            securityContract.revokeRole(
                securityContract.DEFAULT_ADMIN_ROLE(),
                address(this)
            );
            securityContract.revokeRole(MASTER_ADMIN_ROLE, address(this));
        }
        vm.stopBroadcast();
        return
            DclexContracts({
                signatureUtils: signatureUtils,
                stocksFactory: stocksFactory,
                digitalIdentity: digitalIdentity,
                vault: vault,
                tokenBuilder: tokenBuilder,
                usdcMock: usdcMock
            });
    }
}
