// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep } from "contracts/dex/SwapTypes.sol";
import {
    IUniswapV2Router02
} from "contracts/interfaces/external/uniswap/IUniswapV2Router02.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";

/// @title UniswapV2FotAdapter
/// @notice Transfer-tax-tolerant sibling of `UniswapV2Adapter`, dispatched
/// from its own `DexType.UniswapV2Fot` slot. Identical plumbing — pull from
/// `SwapRouter`, approve the V2 router, swap into `msg.sender`,
/// revoke — with one difference: it encodes
/// `swapExactTokensForTokensSupportingFeeOnTransferTokens` instead of
/// `swapExactTokensForTokens`.
///
/// @dev Why a second adapter rather than a fix in place. Plain
/// `swapExactTokensForTokens` derives every hop's output from the GROSS
/// `amountIn` via `getAmountsOut`, then hands that precomputed figure to
/// `pair.swap()`. A transfer-taxed token delivers less than `amountIn` to the
/// pair, so the pair is asked for an output its post-transfer reserves cannot
/// back and the constant-product check reverts `UniswapV2: K` — the swap is
/// unroutable, not merely mispriced. The `SupportingFeeOnTransferTokens`
/// variant instead measures the pair's own balance delta after the transfer
/// and derives the output from that, so the tax is absorbed.
///
/// Everything around this was already tax-correct: `SwapRouter._pullInput`
/// returns the measured balance delta rather than the requested amount, and
/// `_dispatchAdapter` takes its own `tokenOut` delta as the authoritative
/// output, so hops chain on real amounts. The encoded selector was the whole
/// gap.
///
/// The cost of the FoT variant is that it returns nothing — the router's
/// balance delta is the only output signal. That is exactly what `SwapRouter`
/// already relies on (`_swap` returns 0 here, as in every adapter), so no
/// bound is lost: `minAmountOut` is enforced by `SwapRouter` on the measured
/// delta.
///
/// Registered per chain with
/// `setDexAdapter(uint8(DexType.UniswapV2Fot), ...)`, alongside — not
/// replacing — `UniswapV2Adapter` on `DexType.UniswapV2`. Its own slot means
/// only a route the encoder has measured as taxed pays the FoT entry point,
/// so a chain no longer has to have EVERY allow-listed V2 router implement
/// `SupportingFeeOnTransferTokens` before it can serve taxed pools; the
/// encoder is responsible for emitting slot 22 only for a router that does.
/// That entry point is a Router02 addition, absent from bare Router01 forks.
///
/// Rollout order matters on a chain where this adapter already occupies slot
/// 0: register slot 22 and switch the encoder onto it BEFORE restoring
/// `UniswapV2Adapter` to slot 0. Restoring first sends taxed routes — which
/// the encoder still encodes as slot 0 — back to `swapExactTokensForTokens`
/// and reinstates the `UniswapV2: K` revert this adapter exists to remove.
contract UniswapV2FotAdapter is DexAdapterBase {
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
    ) internal override returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = step.tokenIn;
        path[1] = step.tokenOut;

        // `amountOutMin` is 0 for the same reason as every other adapter in
        // this codebase: the real bound is `SwapRouter`'s top-level
        // `minAmountOut`, applied to the measured `tokenOut` delta. A
        // per-step bound here would be denominated in an amount the caller
        // never quoted.
        bytes memory data = abi.encodeCall(
            IUniswapV2Router02
                .swapExactTokensForTokensSupportingFeeOnTransferTokens,
            (amountIn, 0, path, msg.sender, block.timestamp)
        );

        _swapViaRouter(step.tokenIn, amountIn, step.router, data);
        return 0;
    }
}
