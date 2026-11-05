// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";

abstract contract BalancerStrategyEvents {
    event BalancerDeposited(
        Sickle indexed sickle, address indexed pool, address indexed gauge
    );

    event BalancerWithdrawn(
        Sickle indexed sickle,
        address indexed pool,
        address indexed gauge,
        uint256 bptAmount
    );

    event BalancerHarvested(
        Sickle indexed sickle, address indexed pool, address indexed gauge
    );

    event BalancerCompounded(
        Sickle indexed sickle, address indexed pool, address indexed gauge
    );

    event BalancerExited(
        Sickle indexed sickle,
        address indexed pool,
        address indexed gauge,
        uint256 bptAmount
    );

    event BalancerMoved(
        Sickle indexed sickle,
        address indexed fromPool,
        address fromGauge,
        address indexed toPool,
        address toGauge
    );
}
