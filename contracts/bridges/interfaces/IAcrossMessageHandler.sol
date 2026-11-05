// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title IAcrossMessageHandler
/// @notice Interface for contracts that receive cross-chain messages via Across
interface IAcrossMessageHandler {
    /// @notice Called by Across SpokePool when bridged tokens arrive with a
    /// message
    /// @param tokenSent Address of the token delivered
    /// @param amount Amount of tokens delivered
    /// @param relayer Address of the relayer that filled the deposit
    /// @param message Encoded destination-chain execution params
    function handleV3AcrossMessage(
        address tokenSent,
        uint256 amount,
        address relayer,
        bytes memory message
    ) external;
}
