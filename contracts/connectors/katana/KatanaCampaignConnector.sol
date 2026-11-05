// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    IKatanaCampaignPayout
} from "contracts/interfaces/external/katana/IKatanaCampaignPayout.sol";
import {
    KatanaCampaignClaimExtraData
} from "contracts/structs/KatanaStructs.sol";

/// @title KatanaCampaignConnector
/// @notice Claim-only connector for Katana dashboard campaign payouts.
/// @dev Farm.stakingContract should be the KatanaCampaignPayout contract.
contract KatanaCampaignConnector is IFarmConnector {
    error InvalidClaimData();
    error NotImplemented();

    function deposit(
        Farm calldata,
        address,
        bytes memory
    ) external pure override {
        revert NotImplemented();
    }

    function withdraw(
        Farm calldata,
        uint256,
        bytes memory
    ) external pure override {
        revert NotImplemented();
    }

    /// @notice Claims Katana campaign rewards for this Sickle.
    /// @dev Connectors run through Sickle.delegatecall, so address(this) is the
    /// Sickle. Receivers are derived here instead of supplied by extraData so
    /// the dashboard proof can only route rewards to the caller's Sickle.
    function claim(
        Farm calldata farm,
        bytes memory extraData
    ) external override {
        if (extraData.length == 0) return;

        KatanaCampaignClaimExtraData memory claimExtraData =
            abi.decode(extraData, (KatanaCampaignClaimExtraData));

        uint256 length = claimExtraData.campaignIds.length;
        if (
            length != claimExtraData.campaignPayouts.length
                || length != claimExtraData.additionalData.length
        ) {
            revert InvalidClaimData();
        }

        address[] memory receivers = new address[](length);
        for (uint256 i; i < length;) {
            receivers[i] = address(this);
            unchecked {
                i++;
            }
        }

        IKatanaCampaignPayout(farm.stakingContract)
            .batchClaimCampaignPayout(
                claimExtraData.campaignIds,
                receivers,
                claimExtraData.campaignPayouts,
                claimExtraData.additionalData
            );
    }

    function balanceOf(
        Farm calldata,
        address
    ) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Campaign rewards are proven off-chain, so on-chain earned
    /// returns zero placeholders for the requested reward tokens.
    function earned(
        Farm calldata,
        address,
        address[] calldata rewardTokens
    ) external pure override returns (uint256[] memory) {
        return new uint256[](rewardTokens.length);
    }

    function isStaked(
        Farm calldata,
        address
    ) external pure override returns (bool) {
        return false;
    }
}
