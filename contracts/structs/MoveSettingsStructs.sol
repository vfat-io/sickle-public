// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import {
    MultiCompoundConfig
} from "contracts/MultiCompoundSettingsRegistry.sol";

/// @notice A compound-group target shared by ordinary and migration moves.
struct CompoundTarget {
    Farm farm;
    bytes32 poolId;
    address pool;
}

/// @notice A logical position, independent of its protocol's execution ABI.
/// A zero manager identifies an ERC20 farm. NFT pools use either pool or
/// poolId.
struct MovePosition {
    address manager;
    uint256 tokenId;
    Farm farm;
    address pool;
    bytes32 poolId;
}

/// @dev Captured before principal moves. Partial sources retain their policies.
struct MoveSourceSettings {
    MovePosition position;
    bool full;
    uint8 exitDelay;
    MultiCompoundConfig compound;
}
