// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    IGmxOrderCallbackReceiver,
    GmxEvent
} from "contracts/interfaces/external/gmx/IGmxV2.sol";

// Singleton callback contract registered on every Sickle-submitted GMX V2
// order. The Sickle has no on-chain accounting state — this contract exists
// purely so off-chain monitors can subscribe to a single address for order
// lifecycle events.
//
// Only the configured GMX OrderHandler is allowed to invoke the callback;
// arbitrary callers cannot spoof events.
contract GmxV2OrderCallback is IGmxOrderCallbackReceiver {
    event OrderExecuted(bytes32 indexed key);
    event OrderCancelled(bytes32 indexed key);
    event OrderFrozen(bytes32 indexed key);

    error UnauthorizedCallback();

    address public immutable orderHandler;

    constructor(
        address orderHandler_
    ) {
        orderHandler = orderHandler_;
    }

    modifier onlyOrderHandler() {
        if (msg.sender != orderHandler) revert UnauthorizedCallback();
        _;
    }

    function afterOrderExecution(
        bytes32 key,
        GmxEvent.EventLogData calldata,
        GmxEvent.EventLogData calldata
    ) external onlyOrderHandler {
        emit OrderExecuted(key);
    }

    function afterOrderCancellation(
        bytes32 key,
        GmxEvent.EventLogData calldata,
        GmxEvent.EventLogData calldata
    ) external onlyOrderHandler {
        emit OrderCancelled(key);
    }

    function afterOrderFrozen(
        bytes32 key,
        GmxEvent.EventLogData calldata,
        GmxEvent.EventLogData calldata
    ) external onlyOrderHandler {
        emit OrderFrozen(key);
    }
}
