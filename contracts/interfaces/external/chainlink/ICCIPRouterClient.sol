// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Minimal Chainlink CCIP client structs used by the router and
/// receiver interfaces.
/// @dev Mirrors the public v1.6.x EVM ABI without importing the full
/// Chainlink package into this repository.
library CcipClient {
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    struct Any2EVMMessage {
        bytes32 messageId;
        uint64 sourceChainSelector;
        bytes sender;
        bytes data;
        EVMTokenAmount[] destTokenAmounts;
    }

    struct EVM2AnyMessage {
        bytes receiver;
        bytes data;
        EVMTokenAmount[] tokenAmounts;
        address feeToken;
        bytes extraArgs;
    }
}

interface ICCIPRouterClient {
    function ccipSend(
        uint64 destinationChainSelector,
        CcipClient.EVM2AnyMessage calldata message
    ) external payable returns (bytes32 messageId);

    function getFee(
        uint64 destinationChainSelector,
        CcipClient.EVM2AnyMessage calldata message
    ) external view returns (uint256 fee);

    function isChainSupported(
        uint64 destinationChainSelector
    ) external view returns (bool supported);
}

interface IAny2EVMMessageReceiver {
    function ccipReceive(
        CcipClient.Any2EVMMessage calldata message
    ) external;
}
