// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { INuriNonfungiblePositionManager } from
    "contracts/interfaces/external/nuri/INuriNonfungiblePositionManager.sol";
import { NftAddLiquidity } from "contracts/structs/NftLiquidityStructs.sol";
import { RamsesV3Connector } from
    "contracts/connectors/ramses/RamsesV3Connector.sol";
import { IUniswapV3PoolState } from
    "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";

contract NuriV3Connector is RamsesV3Connector {
    function _mint(
        NftAddLiquidity memory addLiquidityParams
    ) internal override {
        INuriNonfungiblePositionManager.MintParams memory params =
        INuriNonfungiblePositionManager.MintParams({
            token0: addLiquidityParams.pool.token0,
            token1: addLiquidityParams.pool.token1,
            fee: addLiquidityParams.pool.fee,
            tickLower: addLiquidityParams.tickLower,
            tickUpper: addLiquidityParams.tickUpper,
            amount0Desired: addLiquidityParams.amount0Desired,
            amount1Desired: addLiquidityParams.amount1Desired,
            amount0Min: addLiquidityParams.amount0Min,
            amount1Min: addLiquidityParams.amount1Min,
            recipient: address(this),
            deadline: block.timestamp
        });

        INuriNonfungiblePositionManager(address(addLiquidityParams.nft)).mint(
            params
        );
    }

    function feeGrowthOutside(
        address pool,
        bytes32, // poolId
        int24 tick
    )
        external
        view
        override
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        (, bytes memory result) = address(pool).staticcall(
            abi.encodeCall(IUniswapV3PoolState.ticks, (tick))
        );
        assembly {
            feeGrowthOutside0X128 := mload(add(result, 96))
            feeGrowthOutside1X128 := mload(add(result, 128))
        }
    }
}
