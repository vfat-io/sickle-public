// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ILiquidityConnector,
    AddLiquidityData,
    RemoveLiquidityData,
    SwapData
} from "contracts/interfaces/ILiquidityConnector.sol";

interface ICurveDepositor3 {
    function add_liquidity(
        address _pool,
        uint256[3] memory _deposit_amounts,
        uint256 _min_mint_amount
    ) external returns (uint256);
    function remove_liquidity_one_coin(
        address _pool,
        uint256 _burn_amount,
        int128 i,
        uint256 _min_received
    ) external returns (uint256);
}

struct CurveDepositor3AddExtraData {
    uint256 minMintAmount;
}

struct CurveDepositor3RemoveExtraData {
    address pool;
    uint256 tokenOutIndex;
}

contract CurveDepositor3Connector is ILiquidityConnector {
    constructor() { }

    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        CurveDepositor3AddExtraData memory extraData = abi.decode(
            addLiquidityData.extraData, (CurveDepositor3AddExtraData)
        );

        uint256[3] memory amounts;
        amounts[0] = addLiquidityData.desiredAmounts[0];
        amounts[1] = addLiquidityData.desiredAmounts[1];
        amounts[2] = addLiquidityData.desiredAmounts[2];

        ICurveDepositor3 depositor = ICurveDepositor3(addLiquidityData.router);
        depositor.add_liquidity(
            addLiquidityData.lpToken, amounts, extraData.minMintAmount
        );
    }

    function removeLiquidity(RemoveLiquidityData memory removeLiquidityData)
        external
        override
    {
        CurveDepositor3RemoveExtraData memory extraData = abi.decode(
            removeLiquidityData.extraData, (CurveDepositor3RemoveExtraData)
        );
        ICurveDepositor3 depositor =
            ICurveDepositor3(removeLiquidityData.router);
        depositor.remove_liquidity_one_coin(
            extraData.pool,
            removeLiquidityData.lpAmountIn,
            int128(int256(extraData.tokenOutIndex)),
            removeLiquidityData.minAmountsOut[extraData.tokenOutIndex]
        );
    }

    function swapExactTokensForTokens(SwapData memory)
        external
        payable
        override
    {
        revert(
            "CurveDepositor3Connector: swapExactTokensForTokens not supported"
        );
    }
}
