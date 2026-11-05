// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CcipSenderBase } from "contracts/bridges/CcipSenderBase.sol";
import { BridgeRouteReceiver } from "contracts/bridges/BridgeRouteReceiver.sol";
import {
    IBridgeAmountAdapter
} from "contracts/interfaces/IBridgeAmountAdapter.sol";

/// @title CcipRouteSender
/// @notice Source-side wrapper for CCIP token + hidden-hub route sends.
/// @dev The destination message data is a `BridgeRouteReceiver.RouteParams`
/// payload consumed by `CcipRouteAdapter`.
///
/// One entrypoint, two shapes:
///   - `forwardAmount == 0`: single-token send. The hub funds any
///     `nextHop.nativeValue` from its own balance (admin-capped via
///     `BridgeRouteReceiver.maxHubNativeFeeByAdapter[CcipRouteAdapter]`).
///   - `forwardAmount > 0`: dual-token send. The hub uses the delivered
///     `forwardToken` (typically CCIP-LINK) as the second-hop fee token.
///     Non-custodial: hub holds no LINK float for these routes.
///   - `forwardAmount > 0` and `params.nativeGasDrop > 0`: the destination
///     adapter treats `forwardToken` as wrapped-native gas-drop funding
///     instead of as a second-hop fee token. Fee-token forwarding and
///     second-token gas-drop cannot be combined in this two-token sender.
contract CcipRouteSender is CcipSenderBase, IBridgeAmountAdapter {
    struct ExactAmountParams {
        address feeToken;
        bytes extraArgs;
        BridgeRouteReceiver.RouteParams params;
    }

    event CcipRouteSent(
        bytes32 indexed messageId,
        address indexed caller,
        address indexed token,
        uint256 bridgedAmount,
        address forwardToken,
        uint256 forwardedAmount,
        address feeToken,
        uint256 fee
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
        address forwardToken,
        uint256 forwardAmount,
        address feeToken,
        bytes calldata extraArgs,
        BridgeRouteReceiver.RouteParams calldata params
    ) external view returns (uint256 fee) {
        _validateRoute(token, params);
        fee = _getFeeForMessage(
            token,
            amount,
            forwardToken,
            forwardAmount,
            feeToken,
            extraArgs,
            abi.encode(params)
        );
    }

    function bridgeRoute(
        address token,
        uint256 amount,
        address forwardToken,
        uint256 forwardAmount,
        address feeToken,
        bytes calldata extraArgs,
        BridgeRouteReceiver.RouteParams calldata params
    )
        external
        payable
        returns (
            bytes32 messageId,
            uint256 bridgedAmount,
            uint256 forwardedAmount,
            uint256 fee
        )
    {
        _validateRoute(token, params);
        (messageId, bridgedAmount, forwardedAmount, fee) = _bridgeMessage(
            token,
            amount,
            forwardToken,
            forwardAmount,
            feeToken,
            extraArgs,
            abi.encode(params)
        );

        emit CcipRouteSent(
            messageId,
            msg.sender,
            token,
            bridgedAmount,
            forwardToken,
            forwardedAmount,
            feeToken,
            fee
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
        _validateRoute(bridgeToken, decoded.params);
        (
            bytes32 messageId,
            uint256 bridgedAmount,
            uint256 forwardedAmount,
            uint256 fee
        ) = _bridgeMessage(
            bridgeToken,
            amount,
            address(0),
            0,
            decoded.feeToken,
            decoded.extraArgs,
            abi.encode(decoded.params)
        );

        emit CcipRouteSent(
            messageId,
            msg.sender,
            bridgeToken,
            bridgedAmount,
            address(0),
            forwardedAmount,
            decoded.feeToken,
            fee
        );

        return abi.encode(messageId, bridgedAmount, forwardedAmount, fee);
    }

    function _validateRoute(
        address token,
        BridgeRouteReceiver.RouteParams memory params
    ) internal pure {
        if (token == address(0) || params.fallbackRecipient == address(0)) {
            revert ZeroAddress();
        }
    }
}
