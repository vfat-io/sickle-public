// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { NftSettings } from "contracts/structs/NftSettingsStructs.sol";
import {
    PositionSettings
} from "contracts/structs/PositionSettingsStructs.sol";
import {
    MoveToNft,
    MoveToExistingNft,
    MoveToFarm
} from "contracts/structs/CrossFarmMoveStructs.sol";

// 0 is CrossFarmMoveStrategy. 1 is Erc6909CrossFarmMoveStrategy.
// Stored as uint8 so an unknown value reverts UnsupportedFamily
// instead of panicking inside the ABI decoder.
uint8 constant MOVE_FAMILY_STANDARD = 0;
uint8 constant MOVE_FAMILY_ERC6909 = 1;

// 0 moveToNft, 1 moveToExistingNft, 2 moveToFarm.
uint8 constant DESTINATION_NEW_NFT = 0;
uint8 constant DESTINATION_EXISTING_NFT = 1;
uint8 constant DESTINATION_FARM = 2;

struct NewNftLeg {
    uint8 family;
    MoveToNft move;
    NftSettings settings;
    address[] sweepTokens;
}

struct ExistingNftLeg {
    uint8 family;
    MoveToExistingNft move;
    address[] sweepTokens;
}

struct FarmLeg {
    uint8 family;
    MoveToFarm move;
    PositionSettings settings;
    address[] sweepTokens;
}

/// @notice Execution schedule. `index` selects the leg inside the array for
/// `kind`.
struct LegOrder {
    uint8 kind;
    uint256 index;
}

struct LegOutcome {
    uint8 kind;
    address destination;
    uint256 destinationId;
}

/// @notice Emitted by the batcher after each successful leg.
/// @dev Move events are emitted by the delegated bytecode with this contract
/// as the log address. `sourcesHash` covers that leg's source keys in exit
/// order (farm sources, then NFT sources). Declared on an interface because
/// Solidity 0.8.19 has no file-level events.
interface ICrossFarmMoveBatchStrategy {
    event MoveLegExecuted(
        address indexed owner,
        Sickle indexed sickle,
        uint256 indexed legIndex,
        uint8 family,
        uint8 kind,
        address destination,
        uint256 destinationId,
        bytes32 sourcesHash
    );
}
