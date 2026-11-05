// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    INftFarmConnector,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import {
    IAeroClGauge
} from "contracts/interfaces/external/aero/IAeroClGauge.sol";

/// @notice Connector for the Aero MetaDEX Slipstream gauge release. It is
/// separate from the legacy Slipstream connector because the reward ABI was
/// changed from getReward(tokenId) to claimEmissions(account,recipient,ids).
contract AeroClGaugeConnector is INftFarmConnector {
    error InvalidNft();

    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external override {
        if (
            IAeroClGauge(position.farm.stakingContract).nft()
                != address(position.nft)
        ) {
            revert InvalidNft();
        }
        IERC721(address(position.nft))
            .approve(position.farm.stakingContract, position.tokenId);
        IAeroClGauge(position.farm.stakingContract).deposit(position.tokenId);
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external override {
        IAeroClGauge gauge = IAeroClGauge(position.farm.stakingContract);
        if (gauge.stakedContains(address(this), position.tokenId)) {
            // The new gauge settles and claims pending emissions on withdrawal.
            gauge.withdraw(position.tokenId);
        }
    }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128, // maxAmount0
        uint128, // maxAmount1
        bytes calldata // extraData
    ) external override {
        IAeroClGauge gauge = IAeroClGauge(position.farm.stakingContract);
        if (gauge.stakedContains(address(this), position.tokenId)) {
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = position.tokenId;
            gauge.claimEmissions(address(this), address(this), tokenIds);
        }
    }

    function earned(
        address user,
        NftPosition calldata position,
        address[] memory // rewardTokens
    ) external view override returns (uint256[] memory rewards) {
        rewards = new uint256[](1);
        IAeroClGauge gauge = IAeroClGauge(position.farm.stakingContract);
        if (gauge.stakedContains(user, position.tokenId)) {
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = position.tokenId;
            rewards[0] = gauge.earned(user, tokenIds);
        }
    }

    function isStaked(
        address user,
        NftPosition calldata position
    ) external view override returns (bool) {
        return IAeroClGauge(position.farm.stakingContract)
            .stakedContains(user, position.tokenId);
    }
}
