// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import { BridgeRouteReceiver } from "contracts/bridges/BridgeRouteReceiver.sol";
import {
    IAcrossMessageHandler
} from "contracts/bridges/interfaces/IAcrossMessageHandler.sol";

contract AcrossRouteAdapter is BridgeAdapterBase, IAcrossMessageHandler {
    BridgeRouteReceiver public immutable receiver;

    constructor(
        address receiver_,
        address admin_,
        address guardian_
    ) BridgeAdapterBase(admin_, guardian_) {
        receiver = BridgeRouteReceiver(payable(receiver_));
    }

    function handleV3AcrossMessage(
        address tokenSent,
        uint256 amount,
        address,
        bytes memory message
    ) external override {
        _onlyWhitelistedEndpoint();
        BridgeRouteReceiver.RouteParams memory params =
            abi.decode(message, (BridgeRouteReceiver.RouteParams));
        uint256 forwarded =
            _forwardAvailable(tokenSent, address(receiver), amount);
        // Across's `handleV3AcrossMessage` does not surface the source-chain
        // sender, so we pass `bytes32(0)`. Any second-hop selector that
        // declares `originatorOffset > 0` (e.g. Stargate deposits) will revert
        // here, which is correct — Across-routed deposits cannot be
        // authenticated, so admins must not register such selectors for Across
        // routes.
        receiver.executeRoute(
            tokenSent, forwarded, address(0), 0, bytes32(0), params
        );
    }
}
