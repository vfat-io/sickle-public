// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Admin } from "contracts/base/Admin.sol";
import { IntentTypes } from "./IntentTypes.sol";
import { ISettlementVerifier } from "./ISettlementVerifier.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title AttestedSettlementVerifier
/// @author vfat.tools
/// @notice MVP settlement verifier that accepts EIP-712 attestations from a
/// trusted signer over a specific intent settlement.
contract AttestedSettlementVerifier is Admin, ISettlementVerifier, EIP712 {
    error InvalidAttestor();
    error AttestationExpired();
    error InvalidAttestation();

    bytes32 public constant SETTLEMENT_TYPEHASH = keccak256(
        "IntentSettlement(address intentRouter,bytes32 intentId,address solver,bytes32 routeHash,address deliveredToken,uint256 deliveredAmount,bool fallbackUsed,bytes32 executionHash,uint256 validUntil)"
    );

    event AttestorSet(address oldAttestor, address newAttestor);

    address public attestor;

    constructor(
        address admin_,
        address attestor_
    ) Admin(admin_) EIP712("AttestedSettlementVerifier", "1") {
        if (attestor_ == address(0)) revert InvalidAttestor();
        attestor = attestor_;
        emit AttestorSet(address(0), attestor_);
    }

    function setAttestor(
        address newAttestor
    ) external onlyAdmin {
        if (newAttestor == address(0)) revert InvalidAttestor();
        emit AttestorSet(attestor, newAttestor);
        attestor = newAttestor;
    }

    function settlementDigest(
        address intentRouter,
        IntentTypes.Settlement calldata settlement,
        uint256 validUntil
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SETTLEMENT_TYPEHASH,
                intentRouter,
                settlement.intentId,
                settlement.solver,
                settlement.routeHash,
                settlement.deliveredToken,
                settlement.deliveredAmount,
                settlement.fallbackUsed,
                settlement.executionHash,
                validUntil
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function verifySettlement(
        address intentRouter,
        IntentTypes.Intent calldata,
        IntentTypes.Settlement calldata settlement
    ) external view {
        (uint256 validUntil, bytes memory signature) =
            abi.decode(settlement.settlementData, (uint256, bytes));

        if (block.timestamp > validUntil) revert AttestationExpired();

        bytes32 digest = settlementDigest(intentRouter, settlement, validUntil);
        (address recovered, ECDSA.RecoverError err) =
            ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != attestor) {
            revert InvalidAttestation();
        }
    }
}
