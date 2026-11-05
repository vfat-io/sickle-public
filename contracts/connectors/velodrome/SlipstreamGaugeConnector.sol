// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    INftFarmConnector,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import { ICLGauge } from "contracts/interfaces/external/aerodrome/ICLGauge.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract SlipstreamGaugeConnector is INftFarmConnector {
    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external {
        IERC721(address(position.nft)).approve(
            position.farm.stakingContract, position.tokenId
        );
        ICLGauge(position.farm.stakingContract).deposit(position.tokenId);
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external {
        ICLGauge gauge = ICLGauge(position.farm.stakingContract);
        // Idempotent: skip the gauge withdraw when the NFT isn't staked (a
        // StakeStrategy flip left it on the Sickle) so withdraw / exit /
        // rebalance don't revert on an unstaked position. Runs via delegatecall,
        // so address(this) is the Sickle.
        if (gauge.stakedContains(address(this), position.tokenId)) {
            gauge.withdraw(position.tokenId);
        }
    }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128, // maxAmount0,
        uint128, // maxAmount1,
        bytes calldata // extraData
    ) external {
        ICLGauge gauge = ICLGauge(position.farm.stakingContract);
        // Idempotent: skip getReward when the NFT isn't staked (a
        // StakeStrategy flip left it on the Sickle), matching withdrawNft,
        // so harvest / rebalance don't revert on an unstaked position.
        if (gauge.stakedContains(address(this), position.tokenId)) {
            gauge.getReward(position.tokenId);
        }
    }

    function isStaked(
        address user,
        NftPosition calldata position
    ) external view virtual override returns (bool) {
        return ICLGauge(position.farm.stakingContract).stakedContains(
            user, position.tokenId
        );
    }

    function earned(
        address user,
        NftPosition calldata position,
        address[] memory // rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        ICLGauge gauge = ICLGauge(position.farm.stakingContract);
        uint256[] memory rewardAmounts = new uint256[](1);
        // gauge.earned reverts when the NFT isn't staked (the gauge requires
        // _stakes[account] to contain the tokenId). After a StakeStrategy
        // flip the NFT is on the Sickle, so read only the residual stored
        // rewards (the pending was paid out by getReward at the flip) — keeping
        // the read-only lens path idempotent, like withdrawNft / claim.
        if (gauge.stakedContains(user, position.tokenId)) {
            rewardAmounts[0] = gauge.earned(user, position.tokenId)
                + gauge.rewards(position.tokenId);
        } else {
            rewardAmounts[0] = gauge.rewards(position.tokenId);
        }
        return rewardAmounts;
    }
}
