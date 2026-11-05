// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IKatanaCampaignPayout {
    function batchClaimCampaignPayout(
        uint256[] calldata campaignIds,
        address[] calldata receivers,
        bytes[] calldata campaignPayouts,
        bytes[] calldata additionalData
    ) external;
}
