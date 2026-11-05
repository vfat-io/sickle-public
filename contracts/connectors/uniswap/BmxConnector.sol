// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    IPositionManager
} from "contracts/interfaces/external/uniswap/v4/IPositionManager.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import {
    PoolKey
} from "contracts/interfaces/external/uniswap/v4/types/PoolKey.sol";
import {
    PoolId
} from "contracts/interfaces/external/uniswap/v4/types/PoolId.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";

interface IBmxDailyEpochGauge {
    function claim(
        uint256 tokenId,
        address to
    ) external returns (uint256);
    function pendingRewardsByTokenId(
        uint256 tokenId
    ) external view returns (uint256);
}

interface IBmxIncentiveGauge {
    function claimAllForOwner(
        PoolId[] calldata pids,
        address owner
    ) external;
    function pendingRewardsByTokenId(
        uint256 tokenId,
        address rewardToken
    ) external view returns (uint256);
}

interface IBmxPositionManagerAdapter {
    function incentiveGauge() external view returns (IBmxIncentiveGauge);
    function dailyEpochGauge() external view returns (IBmxDailyEpochGauge);
}

/**
 * @title BmxConnector
 * @notice Connector for BMX (MorpheusSwap) V4 pools with reward claiming
 * @dev Extends UniswapV4Connector to add BMX-specific reward claiming from
 * DailyEpochGauge and IncentiveGauge
 */
contract BmxConnector is INftFarmConnector {
    address public immutable bmxToken;

    constructor(
        address bmxToken_
    ) {
        bmxToken = bmxToken_;
    }

    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external override {
        IPositionManager(address(position.nft))
            .subscribe(
                position.tokenId, position.farm.stakingContract, extraData
            );
    }

    function earned(
        address, // user
        NftPosition calldata position,
        address[] memory rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](rewardTokens.length);

        IBmxPositionManagerAdapter positionManagerAdapter =
            IBmxPositionManagerAdapter(position.farm.stakingContract);

        // First token (index 0) is assumed to be BMX from daily gauge
        // Tokens from index 1 onwards are assumed to be from incentive gauge
        if (rewardTokens.length > 0 && rewardTokens[0] == bmxToken) {
            rewards[0] = IBmxDailyEpochGauge(
                positionManagerAdapter.dailyEpochGauge()
            ).pendingRewardsByTokenId(position.tokenId);
        }

        for (uint256 i = 1; i < rewardTokens.length; i++) {
            rewards[i] = IBmxIncentiveGauge(
                positionManagerAdapter.incentiveGauge()
            ).pendingRewardsByTokenId(position.tokenId, rewardTokens[i]);
        }

        return rewards;
    }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128,
        uint128,
        bytes calldata // extraData
    ) external override {
        IBmxPositionManagerAdapter positionManagerAdapter =
            IBmxPositionManagerAdapter(position.farm.stakingContract);
        IBmxDailyEpochGauge(positionManagerAdapter.dailyEpochGauge())
            .claim(position.tokenId, address(this));

        (PoolKey memory key,) = IPositionManager(address(position.nft))
            .getPoolAndPositionInfo(position.tokenId);
        PoolId[] memory pids = new PoolId[](1);
        pids[0] = key.toId();
        positionManagerAdapter.incentiveGauge()
            .claimAllForOwner(pids, address(this));
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external override {
        // Unsubscribing is not required
    }

    function isStaked(
        address, // user
        NftPosition calldata
    ) external pure override returns (bool) {
        return false; // NFTs are not staked
    }
}
