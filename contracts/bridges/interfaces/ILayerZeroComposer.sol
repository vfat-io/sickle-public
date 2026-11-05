// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title ILayerZeroComposer
/// @notice Interface for contracts that receive composed messages via
/// LayerZero V2. Used by Stargate V2 to trigger destination-side logic
/// after token delivery.
interface ILayerZeroComposer {
    /// @notice Called by the LayerZero Endpoint after a composed message
    /// is queued by an OApp (e.g., a Stargate pool).
    /// @param _from The OApp that originated the compose (Stargate pool)
    /// @param _guid Unique identifier for the LZ transaction
    /// @param _message Bridge-specific composed payload. Stargate V2
    ///        composes through the OFT envelope:
    ///        nonce (8 bytes) + srcEid (4 bytes) + amountLD (32 bytes)
    ///        + composeFrom (32 bytes) + user composeMsg (remaining bytes)
    /// @param _executor The executor that delivered this compose
    /// @param _extraData Arbitrary extra data from the executor
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}
