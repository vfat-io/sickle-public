// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Aero (Dromos MetaDEX) `VotingRewardsManager`, reduced to the
/// reward estimate views. One manager per gauge pays that pool's fees in
/// `token0`/`token1` and streams incentive programs `1..incentiveCount`.
/// @dev Declared from the verified ABI of the Base deployments.
interface IAeroVotingRewardsManager {
    struct IncentiveProgram {
        address token;
        uint256 amount;
        uint256 rate;
        uint48 start;
        uint48 end;
        address creator;
    }

    function token0() external view returns (address);

    function token1() external view returns (address);

    /// @notice Pending fees, examining at most `maxCheckpoints` user
    /// checkpoints; past the last one it also estimates fees not yet
    /// notified.
    function earnedFees(
        uint256 tokenId,
        uint256 maxCheckpoints
    ) external view returns (uint256, uint256);

    function earnedIncentives(
        uint256 tokenId,
        uint256 programId,
        uint256 maxCheckpoints
    ) external view returns (uint256);

    /// @notice The token's latest user checkpoint here; zero if it never had
    /// weight on this manager's gauge.
    function userRewardCheckpointIndex(
        uint256 tokenId
    ) external view returns (uint256);

    function incentiveCount() external view returns (uint256);

    function incentive(
        uint256 programId
    ) external view returns (IncentiveProgram memory);
}
