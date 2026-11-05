// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IHybraGaugeManager {
    /// @notice Claims gauge rewards for `msg.sender`'s staked `tokenIds`.
    /// @dev Calls `gauge.getReward(tokenId, msg.sender, redeemType)` for each
    /// id; the gauge reverts "NA" unless `msg.sender` staked the id.
    function claimRewards(
        address gauge,
        uint256[] calldata tokenIds,
        uint8 redeemType
    ) external;
}
