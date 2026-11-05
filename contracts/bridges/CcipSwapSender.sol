// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { SwapStep } from "contracts/dex/SwapTypes.sol";

import { CcipSenderBase } from "contracts/bridges/CcipSenderBase.sol";
import {
    IBridgeAmountAdapter
} from "contracts/interfaces/IBridgeAmountAdapter.sol";

/// @title CcipSwapSender
/// @notice Source-side wrapper for CCIP token + destination swap sends.
/// @dev The destination message data is consumed by `CcipSwapAdapter`.
contract CcipSwapSender is CcipSenderBase, IBridgeAmountAdapter {
    struct NativeGasDropTokenParams {
        address token;
        uint256 amount;
    }

    /// @dev `swapDeadline` makes the source-side encoding match the 5-field
    /// destination decode in `CcipSwapAdapter`. Source-chain callers MUST set
    /// this; pass `type(uint256).max` to opt out.
    struct SwapMessage {
        address recipient;
        SwapStep[] swapSteps;
        uint256 minAmountOut;
        uint256 swapDeadline;
    }

    struct ExactAmountParams {
        address feeToken;
        bytes extraArgs;
        address recipient;
        SwapStep[] swapSteps;
        uint256 minAmountOut;
        uint256 nativeGasDrop;
        uint256 swapDeadline;
    }

    event CcipSwapSent(
        bytes32 indexed messageId,
        address indexed caller,
        address indexed token,
        uint256 bridgedAmount,
        address recipient,
        uint256 nativeGasDrop
    );

    event CcipSwapWithNativeGasDropTokenSent(
        bytes32 indexed messageId,
        address indexed caller,
        address indexed token,
        uint256 bridgedAmount,
        address nativeGasDropToken,
        uint256 nativeGasDropAmount,
        address recipient
    );

    constructor(
        address router_,
        uint64 destinationChainSelector_,
        address destinationReceiver_,
        address admin_,
        address guardian_
    )
        CcipSenderBase(
            router_,
            destinationChainSelector_,
            destinationReceiver_,
            admin_,
            guardian_
        )
    { }

    function getFee(
        address token,
        uint256 amount,
        address feeToken,
        bytes calldata extraArgs,
        address recipient,
        SwapStep[] calldata swapSteps,
        uint256 minAmountOut,
        uint256 nativeGasDrop,
        uint256 swapDeadline
    ) external view returns (uint256 fee) {
        _validateSwap(token, recipient);
        bytes memory data = _encodeSwapMessage(
            recipient, swapSteps, minAmountOut, nativeGasDrop, swapDeadline
        );
        fee = _getFeeForMessage(token, amount, feeToken, extraArgs, data);
    }

    function bridgeSwap(
        address token,
        uint256 amount,
        address feeToken,
        bytes calldata extraArgs,
        address recipient,
        SwapStep[] calldata swapSteps,
        uint256 minAmountOut,
        uint256 nativeGasDrop,
        uint256 swapDeadline
    )
        external
        payable
        returns (bytes32 messageId, uint256 bridgedAmount, uint256 fee)
    {
        _validateSwap(token, recipient);
        (messageId, bridgedAmount, fee) = _bridgeMessage(
            token,
            amount,
            feeToken,
            extraArgs,
            abi.encode(
                recipient, swapSteps, minAmountOut, nativeGasDrop, swapDeadline
            )
        );

        emit CcipSwapSent(
            messageId,
            msg.sender,
            token,
            bridgedAmount,
            recipient,
            nativeGasDrop
        );
    }

    function bridgeExactAmount(
        address bridgeToken,
        uint256 amount,
        bytes calldata params
    ) external payable override returns (bytes memory result) {
        ExactAmountParams memory decoded =
            abi.decode(params, (ExactAmountParams));
        _requireExactAmountNativeFee(decoded.feeToken);
        _validateSwap(bridgeToken, decoded.recipient);
        (bytes32 messageId, uint256 bridgedAmount, uint256 fee) = _bridgeMessage(
            bridgeToken,
            amount,
            decoded.feeToken,
            decoded.extraArgs,
            abi.encode(
                decoded.recipient,
                decoded.swapSteps,
                decoded.minAmountOut,
                decoded.nativeGasDrop,
                decoded.swapDeadline
            )
        );

        emit CcipSwapSent(
            messageId,
            msg.sender,
            bridgeToken,
            bridgedAmount,
            decoded.recipient,
            decoded.nativeGasDrop
        );

        return abi.encode(messageId, bridgedAmount, fee);
    }

    function getFeeWithNativeGasDropToken(
        address token,
        uint256 amount,
        NativeGasDropTokenParams calldata nativeGasDrop,
        address feeToken,
        bytes calldata extraArgs,
        SwapMessage calldata swap
    ) external view returns (uint256 fee) {
        _validateSwap(token, swap.recipient);
        bytes memory data = _encodeSwapMessage(swap, 0);
        fee = _getFeeForMessage(
            token,
            amount,
            nativeGasDrop.token,
            nativeGasDrop.amount,
            feeToken,
            extraArgs,
            data
        );
    }

    function bridgeSwapWithNativeGasDropToken(
        address token,
        uint256 amount,
        NativeGasDropTokenParams calldata nativeGasDrop,
        address feeToken,
        bytes calldata extraArgs,
        SwapMessage calldata swap
    )
        external
        payable
        returns (
            bytes32 messageId,
            uint256 bridgedAmount,
            uint256 nativeGasDropDelivered,
            uint256 fee
        )
    {
        _validateSwap(token, swap.recipient);
        bytes memory data = _encodeSwapMessage(swap, 0);
        (messageId, bridgedAmount, nativeGasDropDelivered, fee) = _bridgeMessage(
            token,
            amount,
            nativeGasDrop.token,
            nativeGasDrop.amount,
            feeToken,
            extraArgs,
            data
        );

        emit CcipSwapWithNativeGasDropTokenSent(
            messageId,
            msg.sender,
            token,
            bridgedAmount,
            nativeGasDrop.token,
            nativeGasDropDelivered,
            swap.recipient
        );
    }

    function _encodeSwapMessage(
        SwapMessage calldata swap,
        uint256 nativeGasDrop
    ) internal pure returns (bytes memory) {
        return abi.encode(
            swap.recipient,
            swap.swapSteps,
            swap.minAmountOut,
            nativeGasDrop,
            swap.swapDeadline
        );
    }

    function _encodeSwapMessage(
        address recipient,
        SwapStep[] calldata swapSteps,
        uint256 minAmountOut,
        uint256 nativeGasDrop,
        uint256 swapDeadline
    ) internal pure returns (bytes memory) {
        return abi.encode(
            recipient, swapSteps, minAmountOut, nativeGasDrop, swapDeadline
        );
    }

    function _validateSwap(
        address token,
        address recipient
    ) internal pure {
        if (token == address(0) || recipient == address(0)) {
            revert ZeroAddress();
        }
    }
}
