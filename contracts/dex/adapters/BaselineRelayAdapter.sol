// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IBaselineRelay
} from "contracts/interfaces/external/baseline/IBaselineRelay.sol";

/// @title BaselineRelayAdapter
/// @notice Direct execution for Baseline Mercury pools created without a V4
/// hook. Steps carry the off-chain quoted exact bToken output plus the
/// top-level residual recipient. Buys execute `buyTokensExactOut` and return
/// unused reserves; sells consume the exact input through `sellTokensExactIn`.
/// SwapRouter remains the custodian and measures output.
contract BaselineRelayAdapter is DexAdapterBase {
    error InvalidDexType();
    error InvalidDexData();
    error InvalidRelay();
    error InvalidPoolDirection();
    error HookedPoolNotSupported();
    error NonzeroPoolKey();
    error InvalidInputBalance();
    error InputBalanceConsumed();
    error InvalidResidualBalance();

    address public immutable baselineRelay;

    constructor(
        address admin_,
        address allowlist_,
        address baselineRelay_
    ) DexAdapterBase(admin_, allowlist_) {
        if (baselineRelay_ == address(0)) revert InvalidAddress();
        baselineRelay = baselineRelay_;
    }

    function version() external pure override returns (uint16) {
        return 1;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256) {
        if (step.dexType != uint8(DexType.BaselineRelay)) {
            revert InvalidDexType();
        }
        if (
            step.dexData.length != 64 || amountIn == 0
                || step.tokenIn == address(0) || step.tokenOut == address(0)
                || step.tokenIn == step.tokenOut
        ) revert InvalidDexData();

        (uint256 quotedAmountOut, address residualRecipient) =
            abi.decode(step.dexData, (uint256, address));
        if (quotedAmountOut == 0 || residualRecipient == address(0)) {
            revert InvalidDexData();
        }
        if (step.router != baselineRelay) revert InvalidRelay();

        // Defence in depth: SwapRouter performs the same check before
        // dispatch, but the adapter independently binds every call and
        // approval to the reviewed canonical Relay address.
        allowlist.requireAllowed(step.router);
        IBaselineRelay relay = IBaselineRelay(baselineRelay);

        bool isBuy = relay.reserve(step.tokenOut) == step.tokenIn;
        address bToken;
        if (isBuy) {
            bToken = step.tokenOut;
        } else if (relay.reserve(step.tokenIn) == step.tokenOut) {
            bToken = step.tokenIn;
        } else {
            revert InvalidPoolDirection();
        }
        _requireNativePool(relay, bToken);

        // An exact-out buy can use fewer reserves than `amountIn`. In a route
        // that starts with native currency, SwapRouter's outer residual
        // settlement cannot see the wrapped intermediate token. Snapshot the
        // balance belonging to other routes/callers so this adapter refunds
        // only the residue created by this Baseline step.
        uint256 preExistingInputBalance;
        if (isBuy) {
            uint256 inputBalance = IERC20(step.tokenIn).balanceOf(msg.sender);
            if (inputBalance < amountIn) revert InvalidInputBalance();
            preExistingInputBalance = inputBalance - amountIn;
        }

        _adapterApprove(step.tokenIn, step.router, amountIn);
        if (isBuy) {
            _adapterCall(
                step.router,
                0,
                abi.encodeCall(
                    IBaselineRelay.buyTokensExactOut,
                    (bToken, quotedAmountOut, amountIn)
                )
            );
        } else {
            // The caller-wide SwapRouter minAmountOut is authoritative. Passing
            // zero here avoids replacing user slippage with the raw quote while
            // SwapRouter's output balance delta still enforces delivery.
            _adapterCall(
                step.router,
                0,
                abi.encodeCall(
                    IBaselineRelay.sellTokensExactIn, (bToken, amountIn, 0)
                )
            );
        }
        _adapterApprove(step.tokenIn, step.router, 0);

        if (isBuy) {
            uint256 inputBalanceAfter =
                IERC20(step.tokenIn).balanceOf(msg.sender);
            if (inputBalanceAfter < preExistingInputBalance) {
                revert InputBalanceConsumed();
            }
            uint256 residual = inputBalanceAfter - preExistingInputBalance;
            if (residual > amountIn) revert InvalidResidualBalance();
            if (residual > 0) {
                _adapterPullTo(step.tokenIn, residual, residualRecipient);
            }
        }
        return 0;
    }

    function _requireNativePool(
        IBaselineRelay relay,
        address bToken
    ) internal view {
        if (relay.hasHook(bToken)) revert HookedPoolNotSupported();
        (
            address currency0,
            address currency1,
            uint24 fee,
            int24 tickSpacing,
            address hooks
        ) = relay.poolKey(bToken);
        if (
            currency0 != address(0) || currency1 != address(0) || fee != 0
                || tickSpacing != 0 || hooks != address(0)
        ) revert NonzeroPoolKey();
    }
}
