// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAeroFactoryRegistry {
    function targetToFactory(
        address target
    ) external view returns (address factory);

    function gaugeToTarget(
        address gauge
    ) external view returns (address target);
}
