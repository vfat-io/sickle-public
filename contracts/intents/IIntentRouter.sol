// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IntentTypes } from "./IntentTypes.sol";

interface IIntentRouter {
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDeadline();
    error InvalidDestinationChain();
    error IntentAlreadyExists();
    error IntentNotFound();
    error IntentNotRefundable();
    error ExclusiveSolverOnly();

    event IntentSubmitted(
        bytes32 indexed intentId,
        address indexed owner,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 destinationChainId,
        address tokenOut,
        address recipient,
        IntentTypes.ExecutionMode executionMode,
        address exclusiveSolver,
        uint256 fillDeadline,
        bytes32 routeHash
    );

    event IntentCancelled(bytes32 indexed intentId, address indexed owner);

    event IntentRefunded(
        bytes32 indexed intentId,
        address indexed recipient,
        address token,
        uint256 amount
    );

    event IntentSettled(
        bytes32 indexed intentId,
        address indexed solver,
        bytes32 routeHash,
        address deliveredToken,
        uint256 deliveredAmount,
        bool fallbackUsed,
        bytes32 executionHash
    );

    function submitIntent(
        IntentTypes.Intent calldata intent
    ) external payable returns (bytes32 intentId);

    function cancelExpiredIntent(
        bytes32 intentId
    ) external;

    function submitSettlement(
        IntentTypes.Settlement calldata settlement
    ) external;

    function getIntent(
        bytes32 intentId
    )
        external
        view
        returns (
            IntentTypes.Intent memory intent,
            IntentTypes.IntentState state
        );
}
