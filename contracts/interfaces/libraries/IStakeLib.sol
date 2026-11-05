// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Interface for {StakeLib}, the on-chain emission-vs-fee yield
/// comparison helper for the Aerodrome stake-mode auto-flip. Deployed as a
/// normal helper contract following the repo's existing `*Lib` pattern
/// (SwapLib, ShiftMath, etc.) — NOT a compiler-linked Solidity library — and
/// called via this interface by `StakeStrategy`, so the strategy stays under
/// EIP-170 and the helper is independently deployed/verified per chain.
interface IStakeLib {
    /// @dev Inside fee-growth + time checkpoint the vault snapshots each
    /// harvest. The growth is `feeGrowthInside` for the position's live range
    /// (see {feeGrowthInside}), NOT `feeGrowthGlobal`: only the former tracks
    /// fees the position actually earns. Snapshots are valid to difference only
    /// while the range is unchanged — the vault re-anchors on rebalance.
    struct Snapshot {
        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;
        uint32 timestamp;
    }

    struct Inputs {
        address pool;
        address gauge;
        uint32 twapWindow;
        uint128 liquidity; // the position's liquidity
        int24 tickLower; // position range lower (for inside fee growth)
        int24 tickUpper; // position range upper (for inside fee growth)
        uint256 positionValueToken1; // vault TWAP valuation, token1 terms
        uint256 aeroPriceToken1; // token1 wei per 1e18 AERO, TWAP-derived by the vault
        bool currentlyStaked;
        uint16 unstakedFeeBps; // protocol cut on unstaked swap fees; LP keeps (1 - this)
        uint16 thetaUpBps; // unstake when R >= this (e.g. 12500 = 1.25x)
        uint16 thetaDownBps; // restake when R <= this (e.g. 10000 = 1.0x)
    }

    /// @notice Computes the unstaked/staked yield ratio R and the threshold
    /// signals. R = (net unstaked fee APR) / (staked emission APR), in bps.
    /// @return ratioBps R x 10000 (type(uint256).max when emission APR is 0)
    /// @return favorUnstake R >= thetaUp — fees clear the unstake bar
    /// @return favorStake R <= thetaDown — emissions reclaim the lead
    /// @return feeAprBpsNet net (post-unstakedFee) fee APR, bps
    /// @return emissionAprBps forward emission APR, bps
    function evaluate(
        Inputs memory p,
        Snapshot memory last
    )
        external
        view
        returns (
            uint256 ratioBps,
            bool favorUnstake,
            bool favorStake,
            uint256 feeAprBpsNet,
            uint256 emissionAprBps
        );

    /// @notice Fee growth (X128) accrued strictly inside [tickLower, tickUpper]
    /// for each token. The vault snapshots this each harvest into {Snapshot}.
    function feeGrowthInside(
        address pool,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256 inside0, uint256 inside1);
}
