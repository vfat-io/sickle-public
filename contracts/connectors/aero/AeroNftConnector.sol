// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    SlipstreamNftConnector
} from "contracts/connectors/velodrome/SlipstreamNftConnector.sol";

/// @notice Dedicated deployment target for Aero MetaDEX Slipstream positions.
/// The Batch 1 manager and pool reads used by SlipstreamNftConnector are ABI
/// compatible, while this separate type lets launch config preserve legacy
/// Aerodrome manager mappings independently.
contract AeroNftConnector is SlipstreamNftConnector { }
