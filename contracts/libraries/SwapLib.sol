// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    ILiquidityConnector,
    SwapData
} from "contracts/interfaces/ILiquidityConnector.sol";

contract SwapLib is DelegateModule {
    error SwapAmountZero();

    ConnectorRegistry immutable connectorRegistry;

    constructor(ConnectorRegistry connectorRegistry_) {
        connectorRegistry = connectorRegistry_;
    }

    function swap(SwapData memory swapData) external payable {
        _swap(swapData);
    }

    function swapMultiple(SwapData[] memory swapData) external {
        uint256 swapDataLength = swapData.length;
        for (uint256 i; i < swapDataLength;) {
            _swap(swapData[i]);
            unchecked {
                i++;
            }
        }
    }

    /* Internal Functions */

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
}
