// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    INftFarmConnector,
    Farm,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import { ICLGauge } from "contracts/interfaces/external/aerodrome/ICLGauge.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Enumerable } from
    "@openzeppelin/contracts/interfaces/IERC721Enumerable.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";

contract SlipstreamGaugeConnector is INftFarmConnector {
    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external payable {
        IERC721(address(position.nft)).approve(
            position.farm.stakingContract, position.tokenId
        );
        ICLGauge(position.farm.stakingContract).deposit(position.tokenId);
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external payable {
        ICLGauge(position.farm.stakingContract).withdraw(position.tokenId);
    }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128, // maxAmount0,
        uint128, // maxAmount1,
        bytes calldata // extraData
    ) external payable {
        ICLGauge(position.farm.stakingContract).getReward(position.tokenId);
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
        NftPosition calldata position,
        address[] memory // rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](1);
        rewards[0] =
            ICLGauge(position.farm.stakingContract).rewards(position.tokenId);
        return rewards;
    }
}
