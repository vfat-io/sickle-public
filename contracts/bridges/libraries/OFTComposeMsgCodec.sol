// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title OFTComposeMsgCodec
/// @notice Decodes LayerZero V2 OFT compose messages.
/// @dev Byte layout:
///   [0:8]   nonce       (uint64)
///   [8:12]  srcEid      (uint32)
///   [12:44] amountLD    (uint256) — token amount in local decimals
///   [44:76] composeFrom (bytes32) — original sender on source chain
///   [76:]   composeMsg  (bytes)   — user payload from SendParam.composeMsg
/// Short or malformed messages revert on calldata slicing.
library OFTComposeMsgCodec {
    function srcEid(bytes calldata _message) internal pure returns (uint32) {
        return uint32(bytes4(_message[8:12]));
    }

    /// @notice Extract the token amount in local decimals
    function amountLD(
        bytes calldata _message
    ) internal pure returns (uint256) {
        return uint256(bytes32(_message[12:44]));
    }

    function composeFrom(
        bytes calldata _message
    ) internal pure returns (bytes32) {
        return bytes32(_message[44:76]);
    }

    /// @notice Extract the user compose message payload
    function composeMsg(
        bytes calldata _message
    ) internal pure returns (bytes calldata) {
        return _message[76:];
    }
}
