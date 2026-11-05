// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Aero (Dromos MetaDEX) root `Voter`, reduced to the allocation and
/// claim surface a Sickle connector for sAERO needs.
/// @dev Declared from the verified ABI of the Base deployment
/// (0x49d7d4f17Ec56Ef8fA04E464AF5D1A4942CC31e6). Every mutator here is gated
/// on `VotingEscrow.isAuthorized(msg.sender, tokenId)`, so the escrow owner
/// of the NFT is always authorized. Base is both the root chain and a leaf:
/// a dispatch whose `chainId` is the root chain runs in-process and takes a
/// zero `gasLimit` and zero `value`.
interface IAeroVoter {
    /// @param gauge Gauge to allocate to, strictly ascending in a list.
    /// @param allocated Absolute staked-token amount, not a share; a chain's
    /// list must sum exactly to that chain's budget.
    /// @param data Opaque payload forwarded to the gauge's rewards manager.
    struct GaugeAllocation {
        address gauge;
        uint128 allocated;
        bytes data;
    }

    /// @param delta Staked-token amount added to the chain from the CHAIN0
    /// park; `0` is a refresh poke.
    struct ChainAllocationDispatch {
        uint256 chainId;
        uint128 delta;
        uint256 gasLimit;
        uint256 value;
    }

    struct GaugeAllocationDispatch {
        uint256 chainId;
        uint256 gasLimit;
        uint256 value;
        GaugeAllocation[] gauges;
    }

    struct FeeClaim {
        address votingRewardsManager;
        uint256 maxCheckpoints;
    }

    struct IncentiveClaim {
        address votingRewardsManager;
        uint256 programId;
        uint256 maxCheckpoints;
    }

    /// @param recipient Receives the claimed rewards on the leaf. Wrapped
    /// native rewards arrive as native ETH.
    struct ClaimRewardsParams {
        uint256 chainId;
        uint256 gasLimit;
        uint256 value;
        address recipient;
        FeeClaim[] feeClaims;
        IncentiveClaim[] incentiveClaims;
    }

    /// @notice Add chain budget from the CHAIN0 park, then overwrite the
    /// token's gauge distribution on each listed chain.
    function allocate(
        uint256 tokenId,
        ChainAllocationDispatch[] calldata chainDispatches,
        GaugeAllocationDispatch[] calldata gaugeDispatches,
        address refundRecipient
    ) external payable;

    /// @notice Claim fee and incentive rewards for one token on each listed
    /// chain, paid to each entry's `recipient`.
    function claimRewards(
        uint256 tokenId,
        ClaimRewardsParams[] calldata claimRewardsParams,
        address refundRecipient
    ) external payable;

    function VOTING_ESCROW() external view returns (address);

    function allocationChainAmounts(
        uint256 tokenId,
        uint256 chainId
    ) external view returns (uint128);
}
