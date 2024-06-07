// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import "../../ConnectorRegistry.sol";
import "../../interfaces/ILiquidityConnector.sol";

import "./TransferModule.sol";

contract SwapModule is TransferModule {
    error SwapAmountZero();

    ConnectorRegistry immutable connectorRegistry;

    constructor(
        SickleFactory factory,
        FeesLib feesLib,
        address wrappedNativeAddress,
        ConnectorRegistry connectorRegistry_
    ) TransferModule(factory, feesLib, wrappedNativeAddress) {
        connectorRegistry = connectorRegistry_;
    }

    function _swap(SwapData memory swapData) internal {
        address tokenIn = swapData.tokenIn;

        if (swapData.amountIn == 0) {
            swapData.amountIn = IERC20(tokenIn).balanceOf(address(this));
        }

        if (swapData.amountIn == 0) {
            revert SwapAmountZero();
        }

        // In case there is USDT dust approval, revoke it
        SafeTransferLib.safeApprove(tokenIn, swapData.router, 0);

        SafeTransferLib.safeApprove(tokenIn, swapData.router, swapData.amountIn);

        address connectorAddress =
            connectorRegistry.connectorOf(swapData.router);

        ILiquidityConnector routerConnector =
            ILiquidityConnector(connectorAddress);

        _delegateTo(
            address(routerConnector),
            abi.encodeCall(routerConnector.swapExactTokensForTokens, swapData)
        );

        // Revoke any approval after swap in case the swap amount was estimated
        SafeTransferLib.safeApprove(tokenIn, swapData.router, 0);
    }

    function _sickle_swap(SwapData memory swapData)
        external
        onlyRegisteredSickle
    {
        _swap(swapData);
    }

    function _sickle_swap_multiple(SwapData[] memory swapData)
        external
        onlyRegisteredSickle
    {
        for (uint256 i; i < swapData.length;) {
            _swap(swapData[i]);
            unchecked {
                i++;
            }
        }
    }
}
