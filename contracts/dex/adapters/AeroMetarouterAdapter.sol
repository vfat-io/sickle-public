// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IAeroMetarouter
} from "contracts/interfaces/external/aero/IAeroMetarouter.sol";

/// @title AeroMetarouterAdapter
/// @notice Per-DEX adapter for `DexType.AeroMetarouter` — swaps on Aero
/// (Dromos MetaDEX), covering both V2 pools and CL (Slipstream) pools through
/// the venue's own Metarouter. `step.dexData` is
/// `abi.encode(bool isCL, address[] pools)`, where `pools` is the
/// forward-ordered route.
///
/// Aero's V2 pools cannot be swapped pool-direct the way `SolidlyPoolAdapter`
/// swaps a classic Solidly pair, for two reasons that are properties of the
/// venue rather than gaps in that adapter:
///
/// 1. **No `(tokenA, tokenB, stable)` pool key.** Aero splits stable and
///    volatile pools into separate factories, each keyed `getPool(a, b)`, so
///    there is no three-argument `getPair` to derive a pool from and no
///    `stable` flag on the pool to check it against.
///
/// 2. **`getAmountOut` is not the executable quote.** It deducts only the base
///    fee, while `swap()` deducts the total fee — base plus the priority-fee
///    MEV tax — before the curve invariant is re-checked. Sizing a swap with
///    `getAmountOut` therefore asks for more than the invariant permits and
///    reverts exactly when the MEV tax is live. The Metarouter sizes each hop
///    with `getAmountOutWithTotalFee`, which is the quote that matches
///    execution.
///
/// Authorisation is per-venue, like every other router-style adapter:
/// `SwapRouter._executeStep` runs `requireAllowed` over `step.router`. That is
/// sufficient here because the Metarouter independently proves every pool in
/// the route against `FactoryRegistry.targetToFactory` and the owning
/// factory's `isPool`, and rejects any pool outside the route's family — so an
/// allow-listed Metarouter cannot be pointed at a pool it did not deploy.
///
/// @dev Settlement uses `payerIsUser = true`: the Metarouter pulls the input
/// straight from `SwapRouter` to the first pool against `SwapRouter`'s
/// approval, and never takes custody. Pre-funding the Metarouter instead (the
/// `payerIsUser = false` path `VelodromeUniversalRouterAdapter` uses) would
/// resolve the spend against the Metarouter's *full* token balance and sweep
/// the remainder back at batch close, which lets an unrelated dust transfer to
/// the Metarouter perturb our settlement. Pulling avoids that surface
/// entirely.
contract AeroMetarouterAdapter is DexAdapterBase {
    /// @dev Metarouter command bytes. Exact-input only: `SwapRouter` drives
    /// exact-input steps and measures the output itself.
    uint8 internal constant CL_SWAP_EXACT_IN = 0x00;
    uint8 internal constant V2_SWAP_EXACT_IN = 0x08;

    error EmptyRoute();

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
        (bool isCL, address[] memory pools) =
            abi.decode(step.dexData, (bool, address[]));
        // The Metarouter rejects an empty route too; failing here keeps the
        // revert reason ours rather than an opaque venue error.
        if (pools.length == 0) revert EmptyRoute();

        bytes memory commands =
            abi.encodePacked(isCL ? CL_SWAP_EXACT_IN : V2_SWAP_EXACT_IN);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            IAeroMetarouter.SwapExactInParams({
                pools: pools,
                tokenIn: step.tokenIn,
                amountIn: IAeroMetarouter.BalanceSpend({
                    mode: IAeroMetarouter.SpendMode.Amount,
                    value: amountIn
                }),
                payerIsUser: true,
                // `SwapRouter` enforces the user's slippage bound against its
                // own balance delta, which also covers a route encoded to a
                // token other than `step.tokenOut` (delta zero). A second
                // bound here would only be a less-informed copy of it.
                minAmountOut: 0,
                recipient: msg.sender
            })
        );

        _swapViaRouter(
            step.tokenIn,
            amountIn,
            step.router,
            abi.encodeCall(
                IAeroMetarouter.execute,
                (commands, inputs, block.timestamp)
            )
        );

        // Informational only; SwapRouter's balance delta is authoritative.
        return 0;
    }
}
