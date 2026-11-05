// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title IWormholeCircleIntegration
/// @notice Minimal interface for Wormhole's Circle Integration contract.
/// @dev Supports source-side CCTP initiation with payloads and destination-side
/// atomic redemption into an application contract.
interface IWormholeCircleIntegration {
    struct TransferParameters {
        address token;
        uint256 amount;
        uint16 targetChain;
        bytes32 mintRecipient;
    }

    struct RedeemParameters {
        bytes encodedWormholeMessage;
        bytes circleBridgeMessage;
        bytes circleAttestation;
    }

    struct DepositWithPayload {
        bytes32 token;
        uint256 amount;
        uint32 sourceDomain;
        uint32 targetDomain;
        uint64 nonce;
        bytes32 fromAddress;
        bytes32 mintRecipient;
        bytes payload;
    }

    function transferTokensWithPayload(
        TransferParameters calldata transferParams,
        uint32 batchId,
        bytes calldata payload
    ) external payable returns (uint64 messageSequence);

    function redeemTokensWithPayload(
        RedeemParameters calldata params
    ) external returns (DepositWithPayload memory depositWithPayload);
}
