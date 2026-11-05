// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { IRouterAllowlist } from "contracts/interfaces/IRouterAllowlist.sol";
import { IDexAdapter } from "contracts/dex/IDexAdapter.sol";
import { ISwapRouter } from "contracts/dex/ISwapRouter.sol";
import { SwapStep } from "contracts/dex/SwapTypes.sol";

/// @title DexAdapterBase
/// @notice Shared base for DEX adapters. Adapters in this codebase are
/// pure orchestrators — they decode `step.dexData`, build the target
/// router's calldata, and tell `SwapRouter` what to approve, transfer,
/// or call. They never hold tokens or ETH between (or during) swap
/// steps. `SwapRouter` itself remains `msg.sender` for every external
/// call, which means pool callbacks land on the existing callbacks on
/// `SwapRouter`, FOT accounting stays consistent, and there is no
/// per-step custody surface that a buggy adapter could leak.
///
/// Adapters are bound to their CALLER, not to a stored router. Every
/// callback and every recipient baked into DEX calldata is `msg.sender`, the
/// caller of `swap`, so any SwapRouter that registers an adapter can
/// dispatch to it. Caller binding lets multiple routers share adapters during
/// upgrades without changing the adapter's configuration.
///
/// `swap` is deliberately callable by anyone. An adapter has no authority of
/// its own: it holds no tokens, grants no approvals, and no protocol or
/// registry recognises its address. A caller other than a SwapRouter only
/// drives callbacks into itself. The guard that protects funds lives in the
/// ROUTER: `SwapRouter` accepts `adapterApprove` / `adapterCall` /
/// `adapterPull` / `adapterArmPoolCallback` only from its `_activeAdapter`,
/// set immediately before dispatch and cleared immediately after, and it
/// measures its own balance delta as the authoritative output. A reentrant
/// caller that reaches an adapter mid-dispatch therefore cannot reach the
/// dispatching router through it.
/// @dev Mirrors `contracts/bridges/adapters/BridgeAdapterBase.sol` in
/// spirit (admin + rescue helpers); guardian role is intentionally
/// omitted to match `SwapRouter`'s admin-only governance model.
abstract contract DexAdapterBase is IDexAdapter {
    error NotAdmin();
    error InvalidAddress();

    event AdminUpdated(address oldAdmin, address newAdmin);

    /// @notice Router allowlist shared with `SwapRouter`. Pool/factory-
    /// style adapters read this directly to authorise their factory or
    /// custom deployer checks.
    IRouterAllowlist public immutable allowlist;

    /// @notice Admin authorised to rotate this adapter's admin and
    /// rescue any stuck balances. Adapter swap dispatch itself is
    /// gated by `SwapRouter`'s active-adapter slot, not by this admin.
    address public admin;

    constructor(
        address admin_,
        address allowlist_
    ) {
        if (admin_ == address(0)) revert InvalidAddress();
        if (allowlist_ == address(0)) revert InvalidAddress();
        admin = admin_;
        allowlist = IRouterAllowlist(allowlist_);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @notice Defensive — adapters are not supposed to hold ETH, but
    /// stay payable so an over-refund from a router (e.g. universal
    /// router excess ETH on a partial swap) doesn't get rejected and
    /// can be swept by admin afterwards.
    receive() external payable { }

    /// @notice External `swap` entry point implementing `IDexAdapter`.
    /// Executes one step on behalf of the calling `SwapRouter`. Unguarded by
    /// design; see the contract notice. Concrete adapters override `_swap`.
    function swap(
        SwapStep calldata step,
        uint256 amountIn
    ) external payable override returns (uint256) {
        return _swap(step, amountIn);
    }

    /// @dev Concrete per-DEX implementation. Always invoked via the `swap`
    /// entry point above, so `msg.sender` is the dispatching router.
    /// Adapters have no other external entry point and receive no pool / V4
    /// callbacks (those land on `SwapRouter` or the external router), so
    /// `msg.sender` is never anything else where adapters read it.
    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal virtual returns (uint256);

    function setAdmin(
        address newAdmin
    ) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external virtual onlyAdmin {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    function rescueETH(
        address to
    ) external virtual onlyAdmin {
        SafeTransferLib.safeTransferETH(to, address(this).balance);
    }

    // ── Internal helpers shared by adapter implementations ────────────────

    /// @dev Pull `amount` of `token` from `SwapRouter` directly into
    /// `recipient` (used for pre-deposit-style routers such as
    /// Velodrome's UniversalRouter with `payerIsUser = false`).
    function _adapterPullTo(
        address token,
        uint256 amount,
        address recipient
    ) internal {
        ISwapRouter(msg.sender).adapterPull(token, amount, recipient);
    }

    /// @dev Set an ERC20 approval from `SwapRouter` to `spender`. Use
    /// `amount = 0` to revoke. Wraps `SwapRouter.adapterApprove`.
    function _adapterApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        ISwapRouter(msg.sender).adapterApprove(token, spender, amount);
    }

    /// @dev Execute an external call from `SwapRouter`'s address.
    function _adapterCall(
        address target,
        uint256 value,
        bytes memory data
    ) internal returns (bytes memory) {
        return ISwapRouter(msg.sender).adapterCall(target, value, data);
    }

    /// @dev Arm the V3 / Algebra pool callback before invoking a direct
    /// pool swap via `_adapterCall`.
    function _armPoolCallback(
        address pool,
        address tokenToPay,
        uint256 maxAmountToPay
    ) internal {
        ISwapRouter(msg.sender)
            .adapterArmPoolCallback(pool, tokenToPay, maxAmountToPay);
    }

    /// @dev Resolve the target pool for a direct pool-swap step: the
    /// `(address pool)` (optionally followed by a custom deployer) encoded
    /// in `step.dexData`, falling back to `step.router` when no pool is
    /// encoded. Shared by the V3 and Algebra pool adapters.
    function _decodePoolAddress(
        SwapStep calldata step
    ) internal pure returns (address pool) {
        if (step.dexData.length >= 32) {
            pool = abi.decode(step.dexData, (address));
        } else {
            pool = step.router;
        }
    }

    /// @dev Common router-style swap: `SwapRouter` approves the router,
    /// calls it (with `msg.sender == SwapRouter`), revokes the approval.
    /// Output recipient must be baked into `data` as `msg.sender`.
    function _swapViaRouter(
        address token,
        uint256 amount,
        address router,
        bytes memory data
    ) internal {
        _adapterApprove(token, router, amount);
        _adapterCall(router, 0, data);
        _adapterApprove(token, router, 0);
    }
}
