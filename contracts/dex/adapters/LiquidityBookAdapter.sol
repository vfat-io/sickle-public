// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import { SwapStep } from "contracts/dex/SwapTypes.sol";
import { ILBRouter } from "contracts/interfaces/external/lfj/ILBRouter.sol";
import { ILBFactory } from "contracts/interfaces/external/lfj/ILBFactory.sol";
import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";

/// @notice Swaps against canonical LFJ-compatible Liquidity Book pairs.
/// `step.router` is the allowlisted protocol router and `step.dexData` is
/// `abi.encode(pair)`. The router is used to bind the pair to its factory;
/// the swap itself calls the pair directly so LFJ V2.1, V2.2, Pharaoh, and
/// Ramses share one adapter without assuming identical router swap ABIs.
contract LiquidityBookAdapter is DexAdapterBase {
    error InvalidPair();
    error InvalidTokens();
    error InputTooLarge();
    error PartialFill();
    error FeeOnTransferNotSupported();

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
        if (step.dexData.length != 32) revert InvalidPair();
        ILBPair pair = ILBPair(abi.decode(step.dexData, (address)));
        address factory = pair.getFactory();
        allowlist.requireAllowedFactory(factory);
        if (address(ILBRouter(step.router).getFactory()) != factory) {
            revert InvalidPair();
        }

        IERC20 tokenX = pair.getTokenX();
        IERC20 tokenY = pair.getTokenY();
        if (
            address(
                    ILBFactory(factory)
                    .getLBPairInformation(tokenX, tokenY, pair.getBinStep())
                    .LBPair
                ) != address(pair)
        ) revert InvalidPair();

        bool swapForY;
        if (step.tokenIn == address(tokenX) && step.tokenOut == address(tokenY))
        {
            swapForY = true;
        } else if (
            step.tokenIn == address(tokenY) && step.tokenOut == address(tokenX)
        ) {
            swapForY = false;
        } else {
            revert InvalidTokens();
        }

        if (amountIn > type(uint128).max) revert InputTooLarge();
        (uint128 amountInLeft, uint128 amountOut,) =
            pair.getSwapOut(uint128(amountIn), swapForY);
        if (amountInLeft != 0 || amountOut == 0) revert PartialFill();

        uint256 pairBalanceBefore =
            IERC20(step.tokenIn).balanceOf(address(pair));
        _adapterPullTo(step.tokenIn, amountIn, address(pair));
        if (
            IERC20(step.tokenIn).balanceOf(address(pair)) - pairBalanceBefore
                != amountIn
        ) revert FeeOnTransferNotSupported();

        _adapterCall(
            address(pair),
            0,
            abi.encodeCall(ILBPair.swap, (swapForY, msg.sender))
        );
        return 0;
    }
}
