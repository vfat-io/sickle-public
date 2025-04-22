// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { ILiquidityConnector } from
    "contracts/interfaces/ILiquidityConnector.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import { SwapParams } from "contracts/structs/LiquidityStructs.sol";

address constant UNISWAP_ETH = 0x0000000000000000000000000000000000000000;

contract SwapLib is DelegateModule, ISwapLib {
    error SwapAmountZero();

    ConnectorRegistry immutable connectorRegistry;

    constructor(
        ConnectorRegistry connectorRegistry_
    ) {
        connectorRegistry = connectorRegistry_;
    }

    function swap(
        SwapParams memory swapParams
    ) external payable {
        _swap(swapParams);
    }

    function swapMultiple(
        SwapParams[] memory swapParams
    ) external payable {
        uint256 swapDataLength = swapParams.length;
        for (uint256 i; i < swapDataLength;) {
            _swap(swapParams[i]);
            unchecked {
                i++;
            }
        }
    }

    /* Internal Functions */

    function _swap(
        SwapParams memory swapParams
    ) internal {
        address tokenIn = swapParams.tokenIn;

        bool isNative = tokenIn == UNISWAP_ETH;

        if (swapParams.amountIn == 0) {
            swapParams.amountIn = isNative
                ? address(this).balance
                : IERC20(tokenIn).balanceOf(address(this));
        }

        if (swapParams.amountIn == 0) {
            revert SwapAmountZero();
        }

        if (!isNative) {
            // In case there is USDT dust approval, revoke it
            SafeTransferLib.safeApprove(tokenIn, swapParams.router, 0);
            SafeTransferLib.safeApprove(
                tokenIn, swapParams.router, swapParams.amountIn
            );
        }

        address connectorAddress =
            connectorRegistry.connectorOf(swapParams.router);

        ILiquidityConnector routerConnector =
            ILiquidityConnector(connectorAddress);

        _delegateTo(
            address(routerConnector),
            abi.encodeCall(routerConnector.swapExactTokensForTokens, swapParams)
        );

        if (!isNative) {
            // Revoke any approval after swap in case the swap amount was
            // estimated
            SafeTransferLib.safeApprove(tokenIn, swapParams.router, 0);
        }
    }
}
