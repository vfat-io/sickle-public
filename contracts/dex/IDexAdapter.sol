// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep } from "contracts/dex/SwapTypes.sol";

/// @title IDexAdapter
/// @notice Interface implemented by per-DEX adapter contracts that
/// `SwapRouter` dispatches to when its `dexAdapter[dexType]` slot is set.
/// @dev Under the Option C custody model, the adapter starts with no
/// tokens and pulls them from `SwapRouter` via `adapterPull` while
/// `SwapRouter` holds it as the in-flight active adapter. Output tokens
/// land back in `SwapRouter`, which measures the balance delta to compute
/// the hop's effective output. The function is `payable` so `SwapRouter`
/// can forward native ETH custody alongside the swap when
/// `step.tokenIn == address(0)`. The interface intentionally does not
/// import the concrete `SwapRouter` contract — adapters depend on the
/// shared `SwapTypes` only.
interface IDexAdapter {
    /// @notice Adapter implementation version. Off-chain tooling
    /// (including deployment scripts) reads this to detect which adapter
    /// build is currently wired into `SwapRouter`.
    function version() external view returns (uint16);

    /// @notice Execute a single swap step on behalf of the calling
    /// `SwapRouter`. The adapter addresses every callback and output to its
    /// caller, so any router that registers it may dispatch to it.
    /// @param step Swap step parameters (dex type, router, tokens, dex-
    /// specific data) as defined by `SwapRouter`'s public ABI.
    /// @param amountIn Amount of `step.tokenIn` available for this step.
    /// @return amountOut Amount of `step.tokenOut` the adapter believes
    /// it delivered to `SwapRouter`. Informational only — `SwapRouter`
    /// cross-checks via a balance delta.
    function swap(
        SwapStep calldata step,
        uint256 amountIn
    ) external payable returns (uint256 amountOut);
}
