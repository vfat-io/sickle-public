// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";

/// @notice How the automator should handle accrued GMX funding.
///   * DISABLED   - automator cannot touch funding. Owner can still claim
///                  manually via the strategy's owner-only `harvest`.
///   * TO_WALLET  - automator may call `harvestFor`; funding flows
///                  to the Sickle owner's wallet, position untouched.
///   * COMPOUND   - automator may call `compoundFor`; funding is
///                  claimed to the Sickle and posted back as GMX collateral.
///                  Non-collateral market-token funding can still be
///                  harvested to the wallet because this strategy only
///                  compounds the USD-collateralized short leg.
enum AutoFundingMode {
    DISABLED,
    TO_WALLET,
    COMPOUND
}

/// @notice On-chain authorization for the protocol's Automation contract to
///         act on a user's local GMX short leg.
///
/// The LP leg is intentionally not modeled here. Users may hold LP positions
/// on another chain, so portfolio-level hedge/drift decisions belong to the
/// off-chain automation policy. This struct only bounds what can be done to
/// the GMX leg that exists on this chain.
struct BasisCarrySettings {
    // ---- GMX short identity ----
    address market;
    // The market's long-side collateral token per GMX V2 Market.Props. For
    // markets where both sides post the same token (e.g. synthetic AAVE/USD
    // where long+short collateral are both USDC), set to either USDC or
    // address(0) — the registry validates this against GMX market data and
    // dedupes against `collateralToken` so the same OI key isn't summed twice.
    // For WETH-USD this is WETH; for BTC-USDC it's BTC. Used by the auto-exit
    // funding-rate guard to total OI on each side and by harvestFor to allow
    // wallet-only claiming of non-collateral market-token funding.
    address longToken;
    // Must be the registry's deployment-declared USD collateral token.
    address collateralToken;
    // ---- Authorization flags ----
    bool autoDeleverageEnabled;
    bool autoRebalanceEnabled;
    bool autoExitEnabled;
    // Allows an automator to cancel a pending GMX order owned by this Sickle
    // (e.g. unstick a frozen open/close). Refund still flows to the Sickle
    // owner via GMX's cancellationReceiver field set at order creation, so
    // this is a disruption/grief vector at worst — but disruption of a
    // pending close during stress can leave the hedge in the wrong state,
    // so it gates explicitly on the user's per-Sickle settings rather than
    // riding on Automation's global BASIS_CANCEL_ORDER bit alone.
    bool autoCancelOrderEnabled;
    AutoFundingMode autoFundingMode;
    // ---- Per-call caps (zero means "infinite"; use the bools/mode above
    //      to disable automation) ----
    // Caps the collateral amount an automator can post to GMX in one
    // deleverage / collateral-health action.
    uint256 maxDeleverageCollateralPerCall;
    // Caps the absolute short size delta (GMX 1e30 USD units) the automator
    // can apply in a single rebalance call.
    uint256 maxRebalanceSizeDeltaUsdPerCall;
    // Caps the absolute short size delta (GMX 1e30 USD units) the automator
    // can apply while compounding funding.
    uint256 maxCompoundSizeDeltaUsdPerCall;
    // ---- Local GMX triggers (zero means "flag/cap only") ----
    // Current short leverage in bps (sizeInUsd * 1e4 / collateralUsd).
    // Deleverage is allowed when current leverage > this value.
    uint256 deleverageTriggerLeverageBp;
    // Net funding rate to the short side (annualized, signed bps). Auto-exit
    // fires when the current rate is at or below this threshold.
    int256 exitFundingRateBpThreshold;
    // Minimum claimable funding in 1e30 USD before collateral-token
    // claim/compound is allowed. Non-collateral long-token harvests do not use
    // this threshold because the registry intentionally has no price oracle.
    uint256 minClaimableFundingUsd;
}

struct BasisCarryKey {
    Sickle sickle;
}
