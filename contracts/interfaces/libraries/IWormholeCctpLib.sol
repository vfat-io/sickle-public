// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IWormholeCctpLib
/// @notice Delegatecall-only helper that initiates a Wormhole Circle
/// Integration transfer-with-payload from a Sickle.
interface IWormholeCctpLib {
    error ZeroBridgeAmount();
    error NotDelegatecall();
    error BridgeDidNotConsumeTokens();

    struct TransferArgs {
        address circleIntegration;
        address token;
        uint256 amount;
        uint16 targetChain;
        bytes32 mintRecipient;
        uint32 batchId;
        bytes payload;
    }

    function transferTokensWithPayload(
        TransferArgs calldata transfer
    ) external payable returns (uint64 messageSequence);
}
