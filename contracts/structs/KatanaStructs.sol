// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct KatanaCampaignClaimExtraData {
    uint256[] campaignIds;
    bytes[] campaignPayouts;
    bytes[] additionalData;
}

struct KatanaVKatConvertExtraData {
    uint256[] tokenIds;
    KatanaCampaignClaimExtraData campaignClaim;
}

enum KatanaVKatExitAction {
    BeginWithdrawal,
    ResetVotesAndBeginWithdrawal,
    CancelWithdrawalRequest,
    Withdraw
}

struct KatanaVKatExitExtraData {
    KatanaVKatExitAction action;
    uint256[] tokenIds;
}
