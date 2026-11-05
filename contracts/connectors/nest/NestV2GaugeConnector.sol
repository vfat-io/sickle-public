// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    LithosGaugeConnector
} from "contracts/connectors/lithos/LithosGaugeConnector.sol";
import { IVoter } from "contracts/interfaces/external/aerodrome/IVoter.sol";

contract NestV2GaugeConnector is LithosGaugeConnector {
    constructor(
        IVoter _voter
    ) LithosGaugeConnector(_voter) { }
}
