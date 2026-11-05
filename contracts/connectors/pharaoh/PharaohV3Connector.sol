// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    EtherexV3Connector,
    IEtherexVoter
} from "contracts/connectors/etherex/EtherexV3Connector.sol";

contract PharaohV3Connector is EtherexV3Connector {
    constructor(
        IEtherexVoter voter
    ) EtherexV3Connector(voter) { }
}
