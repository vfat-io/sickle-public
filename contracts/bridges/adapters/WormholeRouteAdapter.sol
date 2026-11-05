// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { WormholeAdapterBase } from "./WormholeAdapterBase.sol";
import { BridgeRouteReceiver } from "contracts/bridges/BridgeRouteReceiver.sol";

contract WormholeRouteAdapter is WormholeAdapterBase {
    error InsufficientNativeForNextHop(uint256 provided, uint256 required);

    BridgeRouteReceiver public immutable receiver;

    constructor(
        address receiver_,
        address tokenBridge_,
        address admin_,
        address guardian_
    ) WormholeAdapterBase(tokenBridge_, admin_, guardian_) {
        receiver = BridgeRouteReceiver(payable(receiver_));
    }

    function executeVAAv1(
        bytes calldata encodedVAA
    ) external payable {
        // Redeem first; any revert below unwinds the one-shot VAA in the
        // same tx, so a failed check leaves it unconsumed and retriable.
        (
            address localToken,
            uint256 received,
            bytes memory transferMsg,
            uint16 emitterChainId,
            bytes32 emitterAddress
        ) = _redeemTransfer(encodedVAA);

        BridgeRouteReceiver.RouteParams memory params =
            abi.decode(transferMsg, (BridgeRouteReceiver.RouteParams));

        // Guard the native fee here, not in receiver.executeRoute: that path
        // catches route reverts into a fallback that consumes the VAA, so
        // reverting here keeps it retriable with correct funding. There is
        // deliberately no swap-deadline guard — hard-reverting on a stale
        // deadline would leave the VAA permanently unredeemable; the swap
        // enforces its own deadline and falls back cleanly instead.
        if (msg.value < params.nextHop.nativeValue) {
            revert InsufficientNativeForNextHop(
                msg.value, params.nextHop.nativeValue
            );
        }

        uint256 routeNativeValue = msg.value;
        if (msg.value > params.nextHop.nativeValue) {
            uint256 nativeGasDrop = msg.value - params.nextHop.nativeValue;
            routeNativeValue = params.nextHop.nativeValue;
            SafeTransferLib.safeTransferETH(
                params.fallbackRecipient, nativeGasDrop
            );
        }

        SafeTransferLib.safeTransfer(localToken, address(receiver), received);
        // Bind originator to the VAA's authenticated emitter pair.
        bytes32 originator =
            keccak256(abi.encode(emitterChainId, emitterAddress));
        receiver.executeRoute{ value: routeNativeValue }(
            localToken, received, address(0), 0, originator, params
        );
    }
}
