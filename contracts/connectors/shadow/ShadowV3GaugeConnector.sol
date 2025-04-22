// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IShadowGaugeV3 } from
    "contracts/interfaces/external/shadow/IShadowGaugeV3.sol";
import { IShadowNonfungiblePositionManager } from
    "contracts/interfaces/external/shadow/IShadowNonfungiblePositionManager.sol";

import {
    INftFarmConnector,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import {
    ShadowV3GaugeClaim,
    ShadowRewardBehavior
} from "contracts/connectors/shadow/ShadowGaugeClaim.sol";

struct ShadowClaimExtraData {
    // claimTokens need to be passed as extraData because xShadow is one of them
    // The default claim behavior in NftFarmStrategy is to transfer the reward
    // tokens to the user at the end, but xShadow is not transferable. This is a
    // workaround.
    address[] claimTokens;
    ShadowRewardBehavior behavior;
}

contract ShadowV3GaugeConnector is INftFarmConnector, ShadowV3GaugeClaim {
    function depositExistingNft(
        NftPosition calldata,
        bytes calldata // extraData
    ) external payable { }

    function withdrawNft(
        NftPosition calldata,
        bytes calldata // extraData
    ) external payable { }
    // Payable in case an NFT is withdrawn to be increased with ETH

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens not used here
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata extraData
    ) external payable {
        ShadowClaimExtraData memory extra =
            abi.decode(extraData, (ShadowClaimExtraData));
        try IShadowNonfungiblePositionManager(address(position.nft)).getReward(
            position.tokenId, extra.claimTokens
        ) {
            // Claim from old gauge for any old rewards, can throw if the old
            // gauge is empty
        } catch { }

        _claimGaugeRewards( // Claim from current gauge
            position.farm.stakingContract,
            position.tokenId,
            extra.claimTokens,
            extra.behavior
        );

        if (amount0Max > 0 || amount1Max > 0) {
            // Claim fees if applicable
            IShadowNonfungiblePositionManager(address(position.nft)).collect(
                IShadowNonfungiblePositionManager.CollectParams({
                    tokenId: position.tokenId,
                    recipient: address(this),
                    amount0Max: amount0Max,
                    amount1Max: amount1Max
                })
            );
        }
    }

    function isStaked(
        address,
        NftPosition calldata
    ) external view virtual override returns (bool) {
        return true; // Shadow positions are staked by default
    }

    function earned(
        NftPosition calldata position,
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        IShadowGaugeV3 gauge = IShadowGaugeV3(position.farm.stakingContract);
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewards[i] = gauge.earned(rewardTokens[i], position.tokenId);
        }
        return rewards;
    }
}
