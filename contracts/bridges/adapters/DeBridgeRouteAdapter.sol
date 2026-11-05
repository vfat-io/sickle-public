// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import { BridgeRouteReceiver } from "contracts/bridges/BridgeRouteReceiver.sol";
import {
    IDeBridgeExternalCallExecutor
} from "contracts/bridges/interfaces/IDeBridgeExternalCallExecutor.sol";

contract DeBridgeRouteAdapter is
    BridgeAdapterBase,
    IDeBridgeExternalCallExecutor
{
    BridgeRouteReceiver public immutable receiver;

    constructor(
        address receiver_,
        address admin_,
        address guardian_
    ) BridgeAdapterBase(admin_, guardian_) {
        receiver = BridgeRouteReceiver(payable(receiver_));
    }

    function onERC20Received(
        bytes32,
        address token,
        uint256 transferredAmount,
        address,
        bytes memory payload
    ) external override returns (bool, bytes memory) {
        _onlyWhitelistedEndpoint();
        BridgeRouteReceiver.RouteParams memory params =
            abi.decode(payload, (BridgeRouteReceiver.RouteParams));
        uint256 forwarded =
            _forwardAvailable(token, address(receiver), transferredAmount);
        // DeBridge's hook surface does not expose the source-chain sender, so
        // we pass `bytes32(0)`. Any second-hop selector that requires an
        // authenticated originator will revert here.
        receiver.executeRoute(
            token, forwarded, address(0), 0, bytes32(0), params
        );
        return (true, new bytes(0));
    }

    function onEtherReceived(
        bytes32,
        address,
        bytes memory
    ) external payable override returns (bool, bytes memory) {
        revert("DeBridgeRouteAdapter: ETH not supported");
    }
}
