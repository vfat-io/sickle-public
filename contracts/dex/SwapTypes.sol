// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice DEX types `SwapRouter` knows how to dispatch. This enum is a
/// set of named constants only — `SwapStep.dexType` is a raw `uint8` (not
/// this enum), so the dispatch table `dexAdapter[uint8]` carries the byte
/// directly with no enum range-check at the ABI boundary. A new *standard*
/// type (allow-listed router + ERC20 `tokenIn`) can therefore be appended
/// and dispatched on an already-deployed `SwapRouter` via `setDexAdapter`
/// alone — no redeploy. NOTE this does NOT cover a type that needs a new
/// `SwapRouter._executeStep` exemption (router-allowlist bypass or
/// native-ETH `tokenIn`); those exemption lists are hardcoded and still
/// require a `SwapRouter` redeploy. Append new entries rather than
/// reordering existing ones.
enum DexType {
    UniswapV2,
    UniswapV3Router02,
    Solidly,
    Algebra,
    UniswapV4,
    VelodromeUniversalRouter,
    UniswapV3Router,
    AerodromeRouter,
    AlgebraPool,
    SlipstreamRouter,
    BlackholeV2Router,
    UniswapV3Pool,
    WrapWETH,
    UnwrapWETH,
    CamelotV2Router,
    PancakeInfinity,
    AaveSupply,
    AaveWithdraw,
    BaselineRelay,
    FlowStateMarket,
    SolidlyPool,
    AeroMetarouter,
    UniswapV2Fot,
    BushAggregatorRouter,
    LiquidityBook,
    CurveStableNgPool,
    MorphoVaultV2Deposit,
    MorphoVaultV2Redeem,
    AeroTokenMigration
}

/// @notice One hop of a multi-step swap. Stable, ABI-stable struct used
/// by `SwapRouter`, every `IDexAdapter`, every bridge swap receiver, and
/// every off-chain encoder (including deployment scripts).
struct SwapStep {
    /// @dev Raw `uint8` (not the `DexType` enum) so dispatch is purely
    /// `dexAdapter[dexType]` — adding a new DEX type never requires
    /// redeploying `SwapRouter`. Compare against `uint8(DexType.X)`.
    uint8 dexType;
    address router;
    address tokenIn;
    address tokenOut;
    bytes dexData;
}
