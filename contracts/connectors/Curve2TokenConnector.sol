// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/ILiquidityConnector.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICurvePool2New {
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
        uint256 i,
        uint256 _min_received
    ) external returns (uint256);
    function remove_liquidity_one_coin(
        uint256 _burn_amount,
        int128 i,
        uint256 _min_received
    ) external returns (uint256);
    function calc_withdraw_one_coin(
        uint256 _burn_amount,
        uint256 i
    ) external returns (uint256);
    function coins(uint256 i) external view returns (address);
    function fee() external view returns (uint256);
    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256);
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external;
}

struct Curve2TokenAddExtraData {
    uint256 minMintAmount;
}

struct Curve2TokenRemoveExtraData {
    uint256 coinIndex;
    uint256 minAmount;
}

struct Curve2TokenExchangeExtraData {
    address tokenOut;
}

contract Curve2TokenConnector is ILiquidityConnector {
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

        ICurvePool2New curvePool = ICurvePool2New(addLiquidityData.router);
        curvePool.add_liquidity(amounts, extraData.minMintAmount);
    }

    function removeLiquidity(RemoveLiquidityData memory removeLiquidityData)
        external
        override
    {
        Curve2TokenRemoveExtraData memory extraData = abi.decode(
            removeLiquidityData.extraData, (Curve2TokenRemoveExtraData)
        );
        ICurvePool2New curvePool = ICurvePool2New(removeLiquidityData.router);
        try curvePool.remove_liquidity_one_coin(
            removeLiquidityData.lpAmountIn,
            extraData.coinIndex,
            extraData.minAmount
        ) { } catch {
            curvePool.remove_liquidity_one_coin(
                removeLiquidityData.lpAmountIn,
                int128(int256(extraData.coinIndex)),
                extraData.minAmount
            );
        }
    }

    function swapExactTokensForTokens(SwapData memory swapData)
        external
        payable
        override
    {
        Curve2TokenExchangeExtraData memory extraData =
            abi.decode(swapData.extraData, (Curve2TokenExchangeExtraData));
        ICurvePool2New curvePool = ICurvePool2New(swapData.router);
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
        curvePool.exchange(i, j, swapData.amountIn, swapData.minAmountOut);
    }
}
