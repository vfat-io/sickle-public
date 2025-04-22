// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    PositionKey,
    PositionSettings
} from "contracts/structs/PositionSettingsStructs.sol";

interface IPositionSettingsRegistry {
    error InvalidStakingContract();
    error InvalidPool();
    error InvalidRouter();
    error SickleNotDeployed();
    error AutoHarvestNotSet();
    error AutoCompoundNotSet();
    error RewardBehaviorNotSet();
    error AutoExitNotSet();
    error ConditionsNotMet();
    error InvalidPrice();
    error InvalidTokenOut();
    error ExitTriggersNotSet();
    error InvalidSlippageBP();
    error InvalidPriceImpactBP();
    error OnlySickle();
    error NonZeroRewardConfig();
    error NonZeroExitConfig();
    error InvalidTriggerReserves();
    error InvalidTokenIndices();
    error InvalidExitTriggers();

    event PositionSettingsSet(PositionKey key, PositionSettings settings);
    event ConnectionRegistrySet(address connectorRegistry);

    function getPositionSettings(
        PositionKey calldata key
    ) external view returns (PositionSettings memory);

    function setPositionSettings(
        PositionKey calldata key,
        PositionSettings calldata settings
    ) external;

    function validateExitFor(
        PositionKey memory key
    ) external;

    function validateHarvestFor(
        PositionKey memory key
    ) external;

    function validateCompoundFor(
        PositionKey memory key
    ) external;
}
