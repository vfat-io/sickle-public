// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IRouterAllowlist } from "contracts/interfaces/IRouterAllowlist.sol";

/// @title ISwapRouter
/// @notice Minimal subset of `SwapRouter` consumed by per-DEX adapters.
/// @dev Lives in its own file (rather than importing `SwapRouter` directly)
/// so the dependency between `DexAdapterBase` and the router stays a thin
/// interface and Solidity doesn't have to resolve the import cycle that
/// `IDexAdapter` already establishes.
interface ISwapRouter {
    /// @notice Move ERC20 custody from the router to `to`. Only callable
    /// by the in-flight active adapter; reverts otherwise.
    function adapterPull(address token, uint256 amount, address to) external;

    /// @notice Set an ERC20 approval from the router itself to
    /// `spender`. Used by router-style adapters so the eventual
    /// `transferFrom` lifts tokens directly from `SwapRouter` rather
    /// than via the adapter (single-FOT-hit accounting).
    function adapterApprove(
        address token,
        address spender,
        uint256 amount
    ) external;

    /// @notice Execute an external call from `SwapRouter` on behalf of
    /// the active adapter. Used so `msg.sender` seen by the target
    /// equals `SwapRouter`.
    function adapterCall(
        address target,
        uint256 value,
        bytes calldata data
    ) external returns (bytes memory);

    /// @notice Arm the V3 / Algebra pool callback for the next direct
    /// pool call in the current adapter dispatch. The callback rejects
    /// any payment whose pool, token, or amount does not match the
    /// armed expectations.
    function adapterArmPoolCallback(
        address pool,
        address tokenToPay,
        uint256 maxAmountToPay
    ) external;

    function allowlist() external view returns (IRouterAllowlist);

    function wrappedNative() external view returns (address);

    function PERMIT2() external view returns (address);

    function PANCAKE_INFINITY_PERMIT2() external view returns (address);
}
