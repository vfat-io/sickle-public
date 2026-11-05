// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IAeroVoter } from "contracts/interfaces/external/aero/IAeroVoter.sol";

/// @param gauge Gauge to allocate to; a vote lists gauges strictly ascending.
/// @param allocated Absolute staked AERO, summing to the token's budget on
/// that chain.
struct AeroGaugeVote {
    address gauge;
    uint128 allocated;
}

/// @notice Parked voting power moved onto one chain before its gauge votes.
/// @param gasLimit Destination gas for a remote chain; zero for Base.
/// @param value Message fee for a remote chain; zero for Base.
struct AeroChainDelta {
    uint256 chainId;
    uint128 delta;
    uint256 gasLimit;
    uint256 value;
}

/// @notice One chain's full gauge distribution.
struct AeroChainGauges {
    uint256 chainId;
    uint256 gasLimit;
    uint256 value;
    AeroGaugeVote[] gauges;
}

/// @notice One token's vote, encoded as `AeroVote[]` in the connector's
/// `vote` extraData. Each list is strictly ascending by chain, as the voter
/// requires.
struct AeroVote {
    uint256 tokenId;
    AeroChainDelta[] chainDeltas;
    AeroChainGauges[] chainGauges;
}

/// @notice One token's Base claims, encoded as `AeroRewardsClaim[]` in the
/// connector's `claim` extraData.
struct AeroRewardsClaim {
    uint256 tokenId;
    IAeroVoter.FeeClaim[] feeClaims;
    IAeroVoter.IncentiveClaim[] incentiveClaims;
}

/// @notice Claims on one remote chain.
struct AeroChainClaim {
    uint256 chainId;
    uint256 gasLimit;
    uint256 value;
    IAeroVoter.FeeClaim[] feeClaims;
    IAeroVoter.IncentiveClaim[] incentiveClaims;
}

/// @notice One token's remote claims, encoded as `AeroRemoteClaim[]` in the
/// connector's `claimRemote` extraData. Chains strictly ascending.
struct AeroRemoteClaim {
    uint256 tokenId;
    AeroChainClaim[] chains;
}
