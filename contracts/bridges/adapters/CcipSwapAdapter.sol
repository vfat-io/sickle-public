// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { SwapStep } from "contracts/dex/SwapTypes.sol";

import { CcipAdapterBase } from "./CcipAdapterBase.sol";
import { BridgeSwapReceiver } from "contracts/bridges/BridgeSwapReceiver.sol";
import { SwapRouter } from "contracts/SwapRouter.sol";
import {
    CcipClient
} from "contracts/interfaces/external/chainlink/ICCIPRouterClient.sol";

/// @title CcipSwapAdapter
/// @notice Receives Chainlink CCIP token + swap messages and forwards them
/// into `BridgeSwapReceiver`.
contract CcipSwapAdapter is CcipAdapterBase {
    error ZeroAddress();

    event CcipSwapReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed sender,
        address token,
        uint256 amount,
        address recipient
    );

    BridgeSwapReceiver public immutable receiver;

    constructor(
        address receiver_,
        address admin_,
        address guardian_
    ) CcipAdapterBase(admin_, guardian_) {
        if (receiver_ == address(0)) revert ZeroAddress();
        receiver = BridgeSwapReceiver(payable(receiver_));
    }

    function ccipReceive(
        CcipClient.Any2EVMMessage calldata message
    ) external override {
        address sender = _authorizeMessage(message);
        uint256 count = message.destTokenAmounts.length;
        if (count != 1 && count != 2) {
            revert InvalidTokenAmountCount(count);
        }
        CcipClient.EVMTokenAmount calldata tokenAmount =
            message.destTokenAmounts[0];

        (
            address recipient,
            SwapStep[] memory swapSteps,
            uint256 minAmountOut,
            uint256 nativeGasDrop,
            uint256 swapDeadline
        ) = abi.decode(
            message.data,
            (address, SwapStep[], uint256, uint256, uint256)
        );

        uint256 forwarded = _forwardDelivered(
            tokenAmount.token, tokenAmount.amount, address(receiver)
        );
        if (count == 1) {
            receiver.executeSwap(
                tokenAmount.token,
                forwarded,
                recipient,
                swapSteps,
                minAmountOut,
                nativeGasDrop,
                swapDeadline
            );
        } else {
            CcipClient.EVMTokenAmount calldata gasAmount =
                message.destTokenAmounts[1];
            _requireDistinctTokens(tokenAmount.token, gasAmount.token);
            uint256 forwardedGas = _forwardDelivered(
                gasAmount.token, gasAmount.amount, address(receiver)
            );
            receiver.executeSwapWithNativeGasDropToken(
                tokenAmount.token,
                forwarded,
                gasAmount.token,
                forwardedGas,
                recipient,
                swapSteps,
                minAmountOut,
                swapDeadline
            );
        }

        emit CcipSwapReceived(
            message.messageId,
            message.sourceChainSelector,
            sender,
            tokenAmount.token,
            forwarded,
            recipient
        );
    }
}
