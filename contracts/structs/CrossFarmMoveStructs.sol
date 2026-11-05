// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    Farm,
    HarvestParams,
    WithdrawParams
} from "contracts/structs/FarmStrategyStructs.sol";
import { ZapIn } from "contracts/structs/ZapStructs.sol";
import {
    NftPosition,
    NftHarvest,
    NftWithdraw,
    NftDeposit,
    NftIncrease
} from "contracts/structs/NftFarmStrategyStructs.sol";
import { NftSettings } from "contracts/structs/NftSettingsStructs.sol";
import {
    PositionSettings
} from "contracts/structs/PositionSettingsStructs.sol";

/// @notice An ERC20 farm position to exit as part of a move
struct FarmSource {
    Farm farm;
    HarvestParams harvest;
    address[] harvestSweepTokens;
    WithdrawParams withdraw;
}

/// @notice An NFT farm position to exit as part of a move
struct NftFarmSource {
    NftPosition position;
    NftHarvest harvest;
    NftWithdraw withdraw;
}

/// @notice Deposit parameters for an ERC20 farm destination
struct FarmDeposit {
    Farm farm;
    ZapIn zap;
    bytes extraData;
}

/// @notice Parameters for moving one or more positions into an NFT farm
struct MoveToNft {
    FarmSource[] farmSources;
    NftFarmSource[] nftSources;
    address[] tokensIn; // Optional additional tokens from user
    uint256[] amountsIn;
    NftDeposit deposit;
}

/// @notice An existing NFT position that receives liquidity from moved sources
struct ExistingNftTarget {
    NftPosition position;
    NftHarvest harvest;
    NftIncrease increase;
}

/// @notice Parameters for moving positions into an existing NFT position
struct MoveToExistingNft {
    FarmSource[] farmSources;
    NftFarmSource[] nftSources;
    address[] tokensIn; // Optional additional tokens from user
    uint256[] amountsIn;
    ExistingNftTarget target;
}

/// @notice Parameters for moving one or more positions into an ERC20 farm
struct MoveToFarm {
    FarmSource[] farmSources;
    NftFarmSource[] nftSources;
    address[] tokensIn; // Optional additional tokens from user
    uint256[] amountsIn;
    FarmDeposit deposit;
}

/// @notice One batch leg that creates an NFT position.
struct NftMove {
    MoveToNft move;
    NftSettings settings;
    address[] sweepTokens;
}

/// @notice One batch leg that deposits into an ERC20 farm.
struct FarmMove {
    MoveToFarm move;
    PositionSettings settings;
    address[] sweepTokens;
}

/// @notice One batch leg that increases an existing NFT position.
struct ExistingNftMove {
    MoveToExistingNft move;
    address[] sweepTokens;
}

/// @notice Independent legs, executed in new-NFT, farm, existing-NFT order.
struct BatchMove {
    NftMove[] nftMoves;
    FarmMove[] farmMoves;
    ExistingNftMove[] existingNftMoves;
}
