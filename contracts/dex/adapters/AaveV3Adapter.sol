// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import { IAaveV3Pool } from "contracts/interfaces/external/aave/IAaveV3Pool.sol";

/// @title AaveV3Adapter
/// @notice Handles `DexType.AaveSupply` (underlying → aToken via
/// `Pool.supply`) and `DexType.AaveWithdraw` (aToken → underlying via
/// `Pool.withdraw`). Modelled on `WrapAdapter`: a 1:1 synthetic "swap"
/// where `SwapRouter` calls the Aave Pool directly via `adapterCall`, so
/// the minted aToken (supply) or returned underlying (withdraw) is
/// credited against the router's own balance and measured by its
/// balance-delta accounting. No tokens ever transit this adapter.
/// @dev `step.router` is the Aave v3 Pool. `step.dexData` is unused — the
/// underlying and aToken are carried by `step.tokenIn` / `step.tokenOut`.
///
/// The `(underlying, aToken)` pairing is validated **from the Pool side**:
/// `Pool.getReserveData(underlying).aTokenAddress` must equal the aToken
/// leg. The Pool — which `SwapRouter` already gates through
/// `RouterAllowlist.requireAllowed` — is the only authority on which aToken
/// backs a reserve. The previous aToken-side check (asking the aToken for
/// its own `UNDERLYING_ASSET_ADDRESS()` / `POOL()`) was insufficient: any
/// contract can self-report those values, so a spoofed `tokenIn` could pass
/// the check while `Pool.withdraw(underlying, …)` burns the router's *real*
/// reserve aToken — draining any stranded aTokens the router holds. Reading
/// the reserve's aToken from the trusted Pool closes that.
contract AaveV3Adapter is DexAdapterBase {
    error InvalidAaveStep();
    error InvalidAaveToken();
    error ReserveDataUnavailable();

    /// @dev `bytes4(keccak256("getReserveData(address)"))`. The aToken
    /// address sits at word index 8 of the returned `ReserveData(Legacy)`
    /// struct — a layout Aave has deliberately kept ABI-stable across v3.0
    /// / v3.1 / v3.2 (verified on eth, base, avax, polygon, optimism,
    /// arbitrum, bnb, sonic, scroll, linea, celo).
    bytes4 private constant GET_RESERVE_DATA_SELECTOR = 0x35ea6a75;
    uint256 private constant ATOKEN_WORD_OFFSET = 8;

    constructor(
        address admin_,
        address allowlist_
    ) DexAdapterBase(admin_, allowlist_) { }

    function version() external pure override returns (uint16) {
        return 1;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256) {
        address pool = step.router;

        if (step.dexType == uint8(DexType.AaveSupply)) {
            // underlying → aToken
            _requireReserveAToken(pool, step.tokenIn, step.tokenOut);
            // Pool pulls the underlying directly from SwapRouter, keeping
            // the single-FOT-hit accounting identical to router swaps.
            _adapterApprove(step.tokenIn, pool, amountIn);
            _adapterCall(
                pool,
                0,
                abi.encodeCall(
                    IAaveV3Pool.supply, (step.tokenIn, amountIn, msg.sender, 0)
                )
            );
            _adapterApprove(step.tokenIn, pool, 0);
            // aToken minted ~1:1 to SwapRouter; output is the balance delta.
            return 0;
        }

        if (step.dexType == uint8(DexType.AaveWithdraw)) {
            // aToken → underlying
            _requireReserveAToken(pool, step.tokenOut, step.tokenIn);
            // No approval: Aave burns the caller's (SwapRouter's) aToken
            // in place. Withdraw the exact measured amount (never
            // type(uint256).max) so intermediate hops stay deterministic.
            _adapterCall(
                pool,
                0,
                abi.encodeCall(
                    IAaveV3Pool.withdraw, (step.tokenOut, amountIn, msg.sender)
                )
            );
            // Underlying sent to SwapRouter; output is the balance delta.
            return 0;
        }

        revert InvalidAaveStep();
    }

    /// @dev Require that `aToken` is the canonical aToken the `pool`
    /// assigns to `underlying`. Authoritative — derived from the trusted
    /// (allow-listed) Pool, not from the caller-supplied token.
    function _requireReserveAToken(
        address pool,
        address underlying,
        address aToken
    ) internal view {
        if (_reserveAToken(pool, underlying) != aToken) {
            revert InvalidAaveToken();
        }
    }

    /// @dev Reads `Pool.getReserveData(underlying).aTokenAddress` via a
    /// low-level staticcall, extracting word index 8 of the static
    /// `ReserveData(Legacy)` return. Reverts `ReserveDataUnavailable` if
    /// the call fails or returns a short payload (e.g. `underlying` is not
    /// a registered reserve on this Pool).
    function _reserveAToken(
        address pool,
        address underlying
    ) internal view returns (address aToken) {
        (bool ok, bytes memory data) = pool.staticcall(
            abi.encodeWithSelector(GET_RESERVE_DATA_SELECTOR, underlying)
        );
        // Need at least words 0..8 present (9 words = 0x120 bytes).
        if (!ok || data.length < (ATOKEN_WORD_OFFSET + 1) * 32) {
            revert ReserveDataUnavailable();
        }
        assembly {
            // data + 0x20 (skip length) + 8 words to reach aTokenAddress.
            aToken :=
                and(
                    mload(add(data, add(0x20, mul(ATOKEN_WORD_OFFSET, 0x20)))),
                    0xffffffffffffffffffffffffffffffffffffffff
                )
        }
        if (aToken == address(0)) revert InvalidAaveToken();
    }
}
