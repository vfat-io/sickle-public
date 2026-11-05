// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title IDeBridgeExternalCallExecutor
/// @notice Interface for deBridge DLN hook targets on the destination chain.
/// The DlnExternalCallAdapter transfers tokens to the target and calls
/// onERC20Received (or onEtherReceived for native) after delivery.
interface IDeBridgeExternalCallExecutor {
    function onEtherReceived(
        bytes32 _orderId,
        address _fallbackAddress,
        bytes memory _payload
    ) external payable returns (bool callSucceeded, bytes memory callResult);

    function onERC20Received(
        bytes32 _orderId,
        address _token,
        uint256 _transferredAmount,
        address _fallbackAddress,
        bytes memory _payload
    ) external returns (bool callSucceeded, bytes memory callResult);
}
