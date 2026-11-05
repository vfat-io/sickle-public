// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import {
    IAlgebraSwapRouter
} from "contracts/interfaces/external/algebra/IAlgebraSwapRouter.sol";
import {
    IAlgebraIntegralSwapRouter
} from "contracts/interfaces/external/algebra/IAlgebraIntegralSwapRouter.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";

/// @title AlgebraRouterAdapter
/// @notice Per-DEX adapter for `DexType.Algebra` covering both classic
/// Algebra (QuickSwap V3 — struct-based selector) and Algebra Integral
/// (8-param selector with explicit deployer). When `dexData.length == 32`
/// it's Integral with `(address deployer)`; otherwise it's classic with
/// empty dexData.
contract AlgebraRouterAdapter is DexAdapterBase {
    /// Nonzero `deployer` arguments are rejected from this router adapter
    /// because we cannot derive the Algebra Integral router's factory on-chain
    /// to authorise the custom deployer. Custom-pool routes must use
    /// `AlgebraPoolAdapter` where the factory and custom deployer are
    /// validated against the pool itself.
    error CustomDeployerMustUsePoolAdapter();

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
        bytes memory data;
        if (step.dexData.length == 32) {
            address deployer = abi.decode(step.dexData, (address));
            if (deployer != address(0)) {
                revert CustomDeployerMustUsePoolAdapter();
            }
            data = abi.encodeWithSelector(
                IAlgebraIntegralSwapRouter.exactInputSingle.selector,
                step.tokenIn,
                step.tokenOut,
                deployer,
                msg.sender,
                block.timestamp,
                amountIn,
                0,
                0
            );
        } else {
            data = abi.encodeWithSelector(
                IAlgebraSwapRouter.exactInputSingle.selector,
                step.tokenIn,
                step.tokenOut,
                msg.sender,
                block.timestamp,
                amountIn,
                0,
                0
            );
        }

        _swapViaRouter(step.tokenIn, amountIn, step.router, data);
        return 0;
    }
}
