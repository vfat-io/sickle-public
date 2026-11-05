// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IAllowanceTransfer
} from "contracts/interfaces/external/IAllowanceTransfer.sol";
import {
    IUniversalRouter
} from "contracts/interfaces/external/uniswap/v4/IUniversalRouter.sol";
import {
    Actions
} from "contracts/interfaces/external/uniswap/v4/libraries/Actions.sol";
import {
    Permit2AllowanceLib
} from "contracts/libraries/Permit2AllowanceLib.sol";
import {
    PoolKey
} from "contracts/interfaces/external/uniswap/v4/types/PoolKey.sol";
import { IHooks } from "contracts/interfaces/external/uniswap/v4/IHooks.sol";
import {
    Currency
} from "contracts/interfaces/external/uniswap/v4/types/Currency.sol";

/// @title UniswapV4ArcAdapter
/// @notice `DexType.UniswapV4` for Arc (5042), whose UniversalRouter requires
/// a 384-byte `ExactInputSingleParams` where the shared `UniswapV4Adapter`
/// emits 352.
///
/// Identical to `UniswapV4Adapter` except for the width of that one struct.
/// It is a separate contract rather than a flag on the shared adapter because
/// the shared one carries live traffic on Base and every other V4 chain, and
/// none of them want this.
///
/// WHAT IS VERIFIED. Arc's router expects one extra 32-byte word between
/// `amountOutMinimum` and the `hookData` offset:
///
///     ours        352 bytes / 11 words
///     Arc wants   384 bytes / 12 words
///
/// A 352-byte payload is 32 bytes short, so the router's calldata decoder
/// reads past the end and reverts with EMPTY data at ~2,076 gas inside
/// `unlockCallback`, with no inner frames. That signature looks nothing like
/// an encoding fault, which is why it was mis-diagnosed repeatedly as an
/// unsupported action or a rejected settle mode. It is neither: the router
/// never gets far enough to read the action list. A NAMED error
/// (`UnsupportedAction` 0x5cda29d7, `SliceOutOfBounds` 0x3b99b53d) means the
/// decoder understood the payload; EMPTY means it read off the end.
///
/// Confirmed against live Arc, same call, only the width changed:
///   352 bytes -> unlockCallback 2,076 gas, empty revert
///   384 bytes -> unlockCallback 53,534 gas, PoolManager.swap EXECUTES, then
///                AllowanceExpired from Permit2 for the unfunded probe caller
///
/// WHAT IS NOT KNOWN, deliberately stated rather than guessed: what the extra
/// word MEANS. It is zero in all twelve live swaps sampled, and its value is
/// ignored -- tested with 0, with the pool's current sqrtPriceX96, with
/// MIN_SQRT_RATIO+1 and with a nonsense 999, all of which execute the swap
/// identically (~53,7xx gas). It is therefore NOT `sqrtPriceLimitX96`: a real
/// price limit set to the current price would halt the trade, and this does
/// not. An earlier revision of this file named it `sqrtPriceLimitX96` on the
/// strength of its position alone. That was a guess and it was wrong.
///
/// Nor is this a case of Arc running an OLDER v4-periphery, which the same
/// revision claimed. Arc launched 2026-09-16 and its router is markedly
/// larger than Base's (24,546 vs 19,499 bytes), so if either side is behind
/// it is more likely ours. The direction is unestablished and nothing here
/// depends on it.
///
/// So the field is written as zero, matching every observed live payload, and
/// named `reserved` because that is all the evidence supports. If its meaning
/// is ever established, rename it and narrow this comment -- do not widen the
/// adapter's behaviour on a guess.
///
/// Slippage is enforced by the strategy's own minimum-out, exactly as in
/// `UniswapV4Adapter`, so nothing here relies on that word.
contract UniswapV4ArcAdapter is DexAdapterBase {
    uint8 internal constant V4_SWAP = 0x10;

    address public constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Arc's 12-word `ExactInputSingleParams`. Declared locally rather
    /// than imported so that updating the shared interface to track upstream
    /// can never silently change what this adapter emits.
    struct ExactInputSingleParamsArc {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        /// @dev Purpose unknown; ignored by the router. See the notice above.
        uint256 reserved;
        bytes hookData;
    }

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
        PoolKey memory poolKey = abi.decode(step.dexData, (PoolKey));
        if (poolKey.hooks != IHooks(address(0))) {
            allowlist.requireAllowedHook(address(poolKey.hooks));
        }

        bool hasFixedPermit2Allowance;
        if (step.tokenIn != address(0)) {
            hasFixedPermit2Allowance = Permit2AllowanceLib.hasFixedAllowance(
                step.tokenIn, msg.sender, PERMIT2
            );
            if (!hasFixedPermit2Allowance) {
                _adapterApprove(step.tokenIn, PERMIT2, amountIn);
            }
            _adapterCall(
                PERMIT2,
                0,
                abi.encodeCall(
                    IAllowanceTransfer.approve,
                    (
                        step.tokenIn,
                        step.router,
                        // forge-lint: disable-next-line(unsafe-typecast)
                        uint160(amountIn),
                        uint48(block.timestamp)
                    )
                )
            );
        }

        {
            bytes memory input = _buildV4Input(step, poolKey, amountIn);
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = input;

            uint256 value = step.tokenIn == address(0) ? amountIn : 0;
            _adapterCall(
                step.router,
                value,
                abi.encodeCall(
                    IUniversalRouter.execute,
                    (abi.encodePacked(V4_SWAP), inputs, block.timestamp)
                )
            );
        }

        if (step.tokenIn != address(0)) {
            if (!hasFixedPermit2Allowance) {
                _adapterApprove(step.tokenIn, PERMIT2, 0);
            }
            _adapterCall(
                PERMIT2,
                0,
                abi.encodeCall(
                    IAllowanceTransfer.approve,
                    (step.tokenIn, step.router, 0, 0)
                )
            );
        }
        return 0;
    }

    function _buildV4Input(
        SwapStep calldata step,
        PoolKey memory poolKey,
        uint256 amountIn
    ) internal pure returns (bytes memory) {
        (address currency0, address currency1) = step.tokenIn < step.tokenOut
            ? (step.tokenIn, step.tokenOut)
            : (step.tokenOut, step.tokenIn);

        bool zeroForOne = step.tokenIn == currency0;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);

        ExactInputSingleParamsArc memory swapParams = ExactInputSingleParamsArc({
            poolKey: PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                fee: poolKey.fee,
                hooks: poolKey.hooks,
                tickSpacing: poolKey.tickSpacing
            }),
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountIn: uint128(amountIn),
            amountOutMinimum: 0,
            reserved: 0,
            hookData: new bytes(0)
        });
        params[0] = abi.encode(swapParams);
        params[1] = abi.encode(step.tokenIn, amountIn);
        params[2] = abi.encode(step.tokenOut, 0);

        return abi.encode(actions, params);
    }
}
