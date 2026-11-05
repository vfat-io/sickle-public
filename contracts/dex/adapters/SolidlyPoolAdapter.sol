// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapStep } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import { ISolidlyPair } from "contracts/interfaces/external/ISolidlyPair.sol";
import {
    ISolidlyPairFactory
} from "contracts/interfaces/external/ISolidlyPairFactory.sol";

/// @title SolidlyPoolAdapter
/// @notice Pool-direct swap against a Solidly / Uniswap-V2 style pair, for
/// venues whose own router cannot swap (Giga "classic" on Robinhood 4663 ships
/// a router with no swap entry point at all).
///
/// `step.router` is the pair **factory**; `step.dexData` is
/// `abi.encode(bool stable)`, byte-identical to `DexType.Solidly`. The pool is
/// never supplied by the caller — it is derived from the factory, so
/// authorisation is per-venue and `SwapRouter` needs no `_executeStep`
/// exemption and no redeploy.
///
/// Two differences from the V3 / Algebra pool adapters:
///
/// 1. **Authorisation.** A V2 pair has no `fee`/`tickSpacing` CREATE2 key to
///    re-derive and no payment callback to re-validate in. So the factory is
///    what `_executeStep` runs `requireAllowed` over, and the adapter derives
///    the pool with `getPair` and asserts `requireAllowedFactory` as well.
///
/// 2. **Settlement.** Pairs are pay-first: the input must be in the pair
///    before `swap`, with no callback to pull it. Input therefore goes
///    straight from `SwapRouter` into the pair, and the quote is taken on
///    `balanceOf(pair) - storedReserveIn` — what the pair itself credits —
///    which keeps it exact for fee-on-transfer inputs and for unsynced
///    donations. Nothing can strand: the pull and the swap share one call
///    frame.
///
/// @dev A factory in the **router** allowlist is approvable by construction:
/// `_swapViaRouter` approves `step.router` unconditionally, so a future
/// router-style `DexType` handed the same address would approve the factory
/// and call it. This adapter never calls `_swapViaRouter`, so the exposure is
/// latent — but no router-style adapter may be pointed at one.
/// The venue's own router is liquidity-only and stays un-allow-listed;
/// allow-listing it could not make the venue routable.
contract SolidlyPoolAdapter is DexAdapterBase {
    error InvalidPool();
    error InvalidTokenIn();
    error NoInputReceived();
    error ZeroAmountOut();

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
        address factory = step.router;
        if (factory == address(0)) revert InvalidAddress();
        bool stable = abi.decode(step.dexData, (bool));

        // Prove the target before any custody moves: pay-first means
        // validating afterwards would be validating after the loss.
        (address pair, bool zeroForOne) =
            _resolvePairAndDirection(factory, step.tokenIn, step.tokenOut, stable);

        (uint256 reserve0, uint256 reserve1,) = ISolidlyPair(pair).getReserves();
        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;

        _adapterPullTo(step.tokenIn, amountIn, pair);

        uint256 balanceIn = IERC20(step.tokenIn).balanceOf(pair);
        if (balanceIn <= reserveIn) revert NoInputReceived();
        uint256 received = balanceIn - reserveIn;

        // `getAmountOut` reads stored reserves and applies the pair's fee,
        // and covers both curves. Never re-derive it.
        uint256 amountOut =
            ISolidlyPair(pair).getAmountOut(received, step.tokenIn);
        if (amountOut == 0) revert ZeroAmountOut();

        // Empty `data`: a payload would make this a flash loan with a
        // callback into `SwapRouter`.
        _adapterCall(
            pair,
            0,
            abi.encodeCall(
                ISolidlyPair.swap,
                (
                    zeroForOne ? 0 : amountOut,
                    zeroForOne ? amountOut : 0,
                    msg.sender,
                    ""
                )
            )
        );

        // Informational only; SwapRouter's balance delta is authoritative.
        return amountOut;
    }

    /// @dev The token check is not redundant with the derivation: it pins
    /// the direction, and backstops a factory vouching for a pool that does
    /// not hold the declared pair.
    function _resolvePairAndDirection(
        address factory,
        address tokenIn,
        address tokenOut,
        bool stable
    ) internal view returns (address pair, bool zeroForOne) {
        allowlist.requireAllowedFactory(factory);

        pair = ISolidlyPairFactory(factory).getPair(tokenIn, tokenOut, stable);
        if (pair == address(0)) revert InvalidPool();

        address token0 = ISolidlyPair(pair).token0();
        address token1 = ISolidlyPair(pair).token1();
        if (tokenIn == token0 && tokenOut == token1) return (pair, true);
        if (tokenIn == token1 && tokenOut == token0) return (pair, false);
        revert InvalidTokenIn();
    }
}
