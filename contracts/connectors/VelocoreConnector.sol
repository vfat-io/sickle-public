// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ILiquidityConnector,
    AddLiquidityData,
    RemoveLiquidityData,
    SwapData
} from "contracts/interfaces/ILiquidityConnector.sol";
import { IUniswapV2Router02 } from
    "contracts/interfaces/external/uniswap/IUniswapV2Router02.sol";
import { IWETH9 } from "contracts/interfaces/external/IWETH.sol";

struct VelocoreExtraData {
    address[] path;
}

contract VelocoreConnector is ILiquidityConnector {
    address public immutable wethContractAddress;

    constructor(address wethContractAddress_) {
        wethContractAddress = wethContractAddress_;
    }

    function swapExactTokensForTokens(SwapData memory swapData)
        external
        payable
        override
    {
        VelocoreExtraData memory extraData =
            abi.decode(swapData.extraData, (VelocoreExtraData));

        uint256 length = extraData.path.length;
        for (uint256 i; i < length;) {
            if (extraData.path[i] == wethContractAddress) {
                extraData.path[i] = address(0); // Velocore implem detail
            }
            unchecked {
                i++;
            }
        }

        uint256[] memory amountsOut;

        if (extraData.path[0] == address(0)) {
            IWETH9(wethContractAddress).withdraw(swapData.amountIn);
            amountsOut = IUniswapV2Router02(swapData.router)
                .swapExactETHForTokens{ value: swapData.amountIn }(
                swapData.minAmountOut,
                extraData.path,
                address(this),
                block.timestamp + 1
            );
        } else {
            amountsOut = IUniswapV2Router02(swapData.router)
                .swapExactTokensForTokens(
                swapData.amountIn,
                swapData.minAmountOut,
                extraData.path,
                address(this),
                block.timestamp + 1
            );
        }

        if (extraData.path[extraData.path.length - 1] == address(0)) {
            IWETH9(wethContractAddress).deposit{
                value: amountsOut[amountsOut.length - 1]
            }();
        }
    }

    function addLiquidity(AddLiquidityData memory) external payable override {
        revert("Not implemented");
    }

    function removeLiquidity(RemoveLiquidityData memory)
        external
        pure
        override
    {
        revert("Not implemented");
    }
}
