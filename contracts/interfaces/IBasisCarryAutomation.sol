// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { GmxV2Connector } from "contracts/connectors/gmx/GmxV2Connector.sol";

interface IBasisCarryAutomation {
    function deleverageFor(
        Sickle sickle,
        GmxV2Connector.OpenShortParams calldata gmxAdd
    ) external payable;

    function rebalanceShortFor(
        Sickle sickle,
        bool isGrow,
        GmxV2Connector.OpenShortParams calldata gmxOpen,
        GmxV2Connector.CloseShortParams calldata gmxClose
    ) external payable;

    function harvestFor(
        Sickle sickle,
        address market,
        address token
    ) external;

    function compoundFor(
        Sickle sickle,
        GmxV2Connector.OpenShortParams calldata gmxAdd
    ) external payable;

    function exitFor(
        Sickle sickle,
        address[] calldata sweepTokens,
        GmxV2Connector.CloseShortParams calldata gmxClose
    ) external payable;

    function cancelOrderFor(
        Sickle sickle,
        bytes32 orderKey
    ) external;
}
