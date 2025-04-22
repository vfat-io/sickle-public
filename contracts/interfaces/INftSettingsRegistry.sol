// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { NftKey, NftSettings } from "contracts/structs/NftSettingsStructs.sol";

interface INftSettingsRegistry {
    error InvalidNftManager();
    error AutoHarvestNotSet();
    error AutoCompoundNotSet();
    error AutoRebalanceNotSet();
    error AutoExitNotSet();
    error ExitTriggersNotSet();
    error InvalidExitTriggers();
    error InvalidTokenOut();
    error InvalidMinMaxTickRange();
    error InvalidSlippageBP();
    error InvalidPriceImpactBP();
    error InvalidDustBP();
    error InvalidMinTickLow();
    error InvalidMaxTickHigh();
    error InvalidBufferTicksAbove();
    error InvalidBufferTicksBelow();
    error OnlySickle();
    error RebalanceConfigNotSet();
    error TickWithinRange();
    error TickOutsideStopLossRange();
    error SickleNotDeployed();
    error InvalidWidth(uint24 actual, uint24 expected);
    error TokenIdUnchanged();

    event NftSettingsSet(NftKey key, NftSettings settings);
    event NftSettingsUnset(NftKey key);
    event ConnectionRegistrySet(address connectorRegistry);

    function getNftSettings(
        NftKey calldata key
    ) external view returns (NftSettings memory);

    function setNftSettings(
        NftKey calldata key,
        NftSettings calldata settings
    ) external;

    function transferNftSettings(
        NftKey calldata oldKey,
        NftSettings calldata settings
    ) external;

    function validateRebalanceFor(
        NftKey memory key
    ) external;

    function validateExitFor(
        NftKey memory key
    ) external;

    function validateHarvestFor(
        NftKey memory key
    ) external;

    function validateCompoundFor(
        NftKey memory key
    ) external;
}
