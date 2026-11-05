// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

library IntentTypes {
    enum IntentState {
        None,
        Submitted,
        Settled,
        Refunded,
        Cancelled
    }

    enum ExecutionMode {
        Strict,
        FallbackToWallet
    }

    struct Input {
        address token;
        uint256 amount;
    }

    struct Output {
        uint256 chainId;
        address token;
        uint256 minAmount;
        address recipient;
    }

    struct SolverConstraints {
        address exclusiveSolver;
        uint256 exclusivityDeadline;
        bytes32 routeHash;
    }

    struct Execution {
        ExecutionMode mode;
        address refundAddress;
        bytes finalAction;
    }

    struct Intent {
        address owner;
        uint256 nonce;
        Input input;
        Output output;
        SolverConstraints solver;
        Execution execution;
        uint256 fillDeadline;
        uint256 refundDelay;
    }

    struct Settlement {
        bytes32 intentId;
        address solver;
        bytes32 routeHash;
        address deliveredToken;
        uint256 deliveredAmount;
        bool fallbackUsed;
        bytes32 executionHash;
        bytes settlementData;
    }
}
