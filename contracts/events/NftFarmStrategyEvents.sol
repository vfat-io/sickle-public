// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";

import { Sickle } from "contracts/Sickle.sol";

abstract contract NftFarmStrategyEvents {
    event SickleDepositedNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed nft,
        uint256 indexed tokenId,
        address stakingContract,
        uint256 poolIndex
    );

    event SickleIncreasedNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed nft,
        uint256 indexed tokenId,
        address stakingContract,
        uint256 poolIndex
    );

    event SickleHarvestedNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed nft,
        uint256 indexed tokenId,
        address stakingContract,
        uint256 poolIndex
    );

    event SickleCompoundedNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed nft,
        uint256 indexed tokenId,
        address stakingContract,
        uint256 poolIndex
    );

    event SickleWithdrewNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed nft,
        uint256 indexed tokenId,
        address stakingContract,
        uint256 poolIndex
    );

    event SickleDecreasedNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed nft,
        uint256 indexed tokenId,
        address stakingContract,
        uint256 poolIndex
    );

    event SickleExitedNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed nft,
        uint256 indexed tokenId,
        address stakingContract,
        uint256 poolIndex
    );

    event SickleRebalancedNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed nft,
        uint256 indexed tokenId,
        address stakingContract,
        uint256 poolIndex
    );

    event SickleMovedNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed fromNft,
        uint256 indexed fromTokenId,
        address fromStakingContract,
        uint256 fromPoolIndex,
        INonfungiblePositionManager toNft,
        uint256 toTokenId,
        address toStakingContract,
        uint256 toPoolIndex
    );
}
