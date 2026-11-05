// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { StargateAdapterBase } from "./StargateAdapterBase.sol";
import { BridgeRouteReceiver } from "contracts/bridges/BridgeRouteReceiver.sol";

contract StargateRouteAdapter is StargateAdapterBase {
    BridgeRouteReceiver public immutable receiver;

    constructor(
        address receiver_,
        address admin_,
        address guardian_,
        address weth_
    ) StargateAdapterBase(admin_, guardian_, weth_) {
        receiver = BridgeRouteReceiver(payable(receiver_));
    }

    function _processCompose(
        address token,
        uint256 amountLD,
        bytes calldata userPayload,
        uint32 srcEid,
        bytes32 composeFrom
    ) internal override {
        token = _prepareInboundToken(token, amountLD);

        BridgeRouteReceiver.RouteParams memory params =
            abi.decode(userPayload, (BridgeRouteReceiver.RouteParams));

        uint256 forwarded =
            _forwardAvailable(token, address(receiver), amountLD);
        // Bind originator to the Stargate-authenticated (srcEid,
        // composeFrom) pair.
        bytes32 originator = keccak256(abi.encode(srcEid, composeFrom));
        receiver.executeRoute{ value: msg.value }(
            token, forwarded, address(0), 0, originator, params
        );
    }
}
