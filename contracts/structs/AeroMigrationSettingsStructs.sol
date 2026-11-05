// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CompoundTarget } from "contracts/structs/MoveSettingsStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import { NftKey } from "contracts/structs/NftSettingsStructs.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";

/// @notice An existing compound-group member whose principal is not migrated.
/// Zero nft/tokenId identifies an ERC20 farm; otherwise farm is its NFT
/// custody.
struct CompoundMember {
    INonfungiblePositionManager nft;
    uint256 tokenId;
    Farm farm;
    uint256 targetLeg;
}

/// @dev Authenticated by the wrapper before any source is removed.
struct AeroMigrationSource {
    INonfungiblePositionManager nft;
    uint256 tokenId;
    Farm farm;
    Farm settingsFarm;
    address lpToken;
    address pool;
}

struct AeroMigrationDestination {
    NftKey key;
    Farm farm;
    address pool;
}
