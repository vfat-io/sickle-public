// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CcipAdapterBase } from "./CcipAdapterBase.sol";
import { BridgeRouteReceiver } from "contracts/bridges/BridgeRouteReceiver.sol";
import {
    CcipClient
} from "contracts/interfaces/external/chainlink/ICCIPRouterClient.sol";

/// @title CcipRouteAdapter
/// @notice Receives Chainlink CCIP token + route messages and forwards them
/// into `BridgeRouteReceiver.executeRoute`.
///
///   - 1 `tokenAmount` → single-token route; receiver second-hop fee
///     funded by hub native float (`maxHubNativeFeeByAdapter[this]`).
///   - 2 `tokenAmounts` and `params.nativeGasDrop == 0` → dual-token route.
///     Position [0] is the bridge token, position [1] is a fee-forwarding
///     token (e.g. CCIP-LINK) packed by `CcipRouteSender`. The receiver
///     approves it to the second-hop bridge for the delivered amount and
///     refunds the unspent leftover to `params.fallbackRecipient`.
///   - 2 `tokenAmounts` and `params.nativeGasDrop > 0` → position [1] is
///     callback-chain wrapped native gas funding. The adapter forwards it to
///     `BridgeRouteReceiver.executeRouteWithNativeGasDropToken` and clears
///     `params.nativeGasDrop` before route execution so the primary token is
///     not also reserved.
contract CcipRouteAdapter is CcipAdapterBase {
    error ZeroAddress();

    struct RouteReceipt {
        address token;
        uint256 amount;
        address feeToken;
        uint256 feeAmount;
    }

    event CcipRouteReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed sender,
        address token,
        uint256 amount,
        address feeToken,
        uint256 feeAmount
    );

    BridgeRouteReceiver public immutable receiver;

    constructor(
        address receiver_,
        address admin_,
        address guardian_
    ) CcipAdapterBase(admin_, guardian_) {
        if (receiver_ == address(0)) revert ZeroAddress();
        receiver = BridgeRouteReceiver(payable(receiver_));
    }

    function ccipReceive(
        CcipClient.Any2EVMMessage calldata message
    ) external override {
        address sender = _authorizeMessage(message);

        BridgeRouteReceiver.RouteParams memory params =
            abi.decode(message.data, (BridgeRouteReceiver.RouteParams));

        // Bind originator to the CCIP-authenticated
        // (sourceChainSelector, sender) pair.
        bytes32 originator =
            keccak256(abi.encode(message.sourceChainSelector, sender));
        RouteReceipt memory receipt =
            _forwardAndExecute(message, params, originator);

        emit CcipRouteReceived(
            message.messageId,
            message.sourceChainSelector,
            sender,
            receipt.token,
            receipt.amount,
            receipt.feeToken,
            receipt.feeAmount
        );
    }

    function _forwardAndExecute(
        CcipClient.Any2EVMMessage calldata message,
        BridgeRouteReceiver.RouteParams memory params,
        bytes32 originator
    ) internal returns (RouteReceipt memory receipt) {
        uint256 count = message.destTokenAmounts.length;
        if (count != 1 && count != 2) {
            revert InvalidTokenAmountCount(count);
        }

        CcipClient.EVMTokenAmount calldata bridgeAmount =
            message.destTokenAmounts[0];
        receipt.token = bridgeAmount.token;
        receipt.amount = _forwardDelivered(
            bridgeAmount.token, bridgeAmount.amount, address(receiver)
        );

        if (count == 2) {
            CcipClient.EVMTokenAmount calldata extraAmount =
                message.destTokenAmounts[1];
            _requireDistinctTokens(bridgeAmount.token, extraAmount.token);
            if (params.nativeGasDrop > 0) {
                _executeDualTokenGasDropPath(
                    receipt, extraAmount, params, originator
                );
                return receipt;
            }
            receipt.feeToken = extraAmount.token;
            receipt.feeAmount = _forwardDelivered(
                extraAmount.token, extraAmount.amount, address(receiver)
            );
        }

        receiver.executeRoute(
            receipt.token,
            receipt.amount,
            receipt.feeToken,
            receipt.feeAmount,
            originator,
            params
        );
    }

    function _executeDualTokenGasDropPath(
        RouteReceipt memory receipt,
        CcipClient.EVMTokenAmount calldata extraAmount,
        BridgeRouteReceiver.RouteParams memory params,
        bytes32 originator
    ) private {
        uint256 forwardedNativeGasDrop = _forwardDelivered(
            extraAmount.token, extraAmount.amount, address(receiver)
        );
        params.nativeGasDrop = 0;
        _executeWithNativeGasDropToken(
            receipt.token,
            receipt.amount,
            extraAmount.token,
            forwardedNativeGasDrop,
            originator,
            params
        );
    }

    function _executeWithNativeGasDropToken(
        address token,
        uint256 amount,
        address nativeGasDropToken,
        uint256 nativeGasDrop,
        bytes32 originator,
        BridgeRouteReceiver.RouteParams memory params
    ) private {
        receiver.executeRouteWithNativeGasDropToken(
            token,
            amount,
            address(0),
            0,
            nativeGasDropToken,
            nativeGasDrop,
            originator,
            params
        );
    }
}
