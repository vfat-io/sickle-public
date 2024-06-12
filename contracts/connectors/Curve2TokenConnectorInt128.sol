// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ILiquidityConnector,
    AddLiquidityData,
    RemoveLiquidityData,
    SwapData
} from "contracts/interfaces/ILiquidityConnector.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    Curve2TokenAddExtraData,
    Curve2TokenRemoveExtraData,
    Curve2TokenExchangeExtraData
} from "contracts/connectors/Curve2TokenConnector.sol";

interface ICurvePool2 {
    function add_liquidity(
        uint256[2] memory _amounts,
        uint256 _min_mint_amount
    ) external returns (uint256);
    function remove_liquidity(
        uint256 _burn_amount,
        uint256[2] memory _min_amounts
    ) external returns (uint256[2] memory);
    function remove_liquidity_one_coin(
        uint256 _burn_amount,
        int128 i,
        uint256 _min_received
    ) external returns (uint256);
    function calc_withdraw_one_coin(
        uint256 _burn_amount,
        int128 i
    ) external returns (uint256);
    function coins(uint256 i) external view returns (address);
    function fee() external view returns (uint256);
    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256);
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external;
}

contract Curve2TokenConnectorInt128 is ILiquidityConnector {
    constructor() { }

    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        Curve2TokenAddExtraData memory extraData =
            abi.decode(addLiquidityData.extraData, (Curve2TokenAddExtraData));

        uint256[2] memory amounts;
        amounts[0] = addLiquidityData.desiredAmounts[0];
        amounts[1] = addLiquidityData.desiredAmounts[1];

        ICurvePool2 curvePool = ICurvePool2(addLiquidityData.router);
        curvePool.add_liquidity(amounts, extraData.minMintAmount);
    }

    function removeLiquidity(RemoveLiquidityData memory removeLiquidityData)
        external
        override
    {
        Curve2TokenRemoveExtraData memory extraData = abi.decode(
            removeLiquidityData.extraData, (Curve2TokenRemoveExtraData)
        );
        ICurvePool2 curvePool = ICurvePool2(removeLiquidityData.router);
        curvePool.remove_liquidity_one_coin(
            removeLiquidityData.lpAmountIn,
            int128(int256(extraData.coinIndex)),
            extraData.minAmount
        );
    }

    function swapExactTokensForTokens(SwapData memory swapData)
        external
        payable
        override
    {
        Curve2TokenExchangeExtraData memory extraData =
            abi.decode(swapData.extraData, (Curve2TokenExchangeExtraData));
        ICurvePool2 curvePool = ICurvePool2(swapData.router);
        uint256 i = 255;
        uint256 j = 255;
        uint256 index = 0;
        while (i == 255 || j == 255) {
            address coin = curvePool.coins(index);
            if (coin == swapData.tokenIn) {
                i = index;
            }
            if (coin == extraData.tokenOut) {
                j = index;
            }
            index++;
        }
        uint256 balance = IERC20(swapData.tokenIn).balanceOf(address(this));
        if (balance < swapData.amountIn) {
            swapData.minAmountOut =
                swapData.minAmountOut * balance / swapData.amountIn * 999 / 1000;
            swapData.amountIn = balance;
        }
        curvePool.exchange(
            int128(int256(i)),
            int128(int256(j)),
            swapData.amountIn,
            swapData.minAmountOut
        );
    }
}
