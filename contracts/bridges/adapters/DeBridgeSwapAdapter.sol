// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { SwapStep } from "contracts/dex/SwapTypes.sol";

import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import { BridgeSwapReceiver } from "contracts/bridges/BridgeSwapReceiver.sol";
import { SwapRouter } from "contracts/SwapRouter.sol";
import {
    IDeBridgeExternalCallExecutor
} from "contracts/bridges/interfaces/IDeBridgeExternalCallExecutor.sol";

/// @title DeBridgeSwapAdapter
/// @notice Receives tokens from deBridge DLN hooks and swaps via
/// BridgeSwapReceiver. The DlnExternalCallAdapter transfers tokens
/// to this contract before calling onERC20Received.
/// @dev Hook configuration: hooks MUST be set to **atomic** so execution
/// runs within the order-fill transaction.  The recommended success mode
/// is **success-optional** with the fallback address set to the token
/// recipient so tokens are recoverable if the swap callback fails.
/// If **success-required** is used instead, ensure the order's destination
/// authority supports cancellation to avoid stuck funds.
contract DeBridgeSwapAdapter is
    BridgeAdapterBase,
    IDeBridgeExternalCallExecutor
{
    BridgeSwapReceiver public immutable receiver;

    constructor(
        address receiver_,
        address admin_,
        address guardian_
    ) BridgeAdapterBase(admin_, guardian_) {
        receiver = BridgeSwapReceiver(payable(receiver_));
    }

    /// @inheritdoc IDeBridgeExternalCallExecutor
    function onERC20Received(
        bytes32, // _orderId
        address _token,
        uint256 _transferredAmount,
        address _fallbackAddress,
        bytes memory _payload
    ) external override returns (bool, bytes memory) {
        _onlyWhitelistedEndpoint();
        (
            SwapStep[] memory swapSteps,
            uint256 minAmountOut,
            uint256 nativeGasDrop,
            uint256 swapDeadline
        ) = abi.decode(
            _payload, (SwapStep[], uint256, uint256, uint256)
        );
        uint256 forwarded =
            _forwardAvailable(_token, address(receiver), _transferredAmount);
        receiver.executeSwap(
            _token,
            forwarded,
            _fallbackAddress,
            swapSteps,
            minAmountOut,
            nativeGasDrop,
            swapDeadline
        );
        return (true, new bytes(0));
    }

    /// @inheritdoc IDeBridgeExternalCallExecutor
    function onEtherReceived(
        bytes32, // _orderId
        address, // _fallbackAddress
        bytes memory // _payload
    ) external payable override returns (bool, bytes memory) {
        revert("DeBridgeSwapAdapter: ETH not supported");
    }
}
