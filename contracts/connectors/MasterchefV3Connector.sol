// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import { IERC721Enumerable } from
    "@openzeppelin/contracts/interfaces/IERC721Enumerable.sol";
import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import {
    ILiquidityConnector,
    AddLiquidityData,
    RemoveLiquidityData,
    SwapData
} from "contracts/interfaces/ILiquidityConnector.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { IMasterchefV3 } from "contracts/interfaces/external/IMasterchefV3.sol";

struct MasterchefV3ExtraData {
    uint256 tokenId;
    bool isIncrease;
    // User's existing NFT balance in the Sickle, typically 0
    uint256 tokenBalance;
    uint128 maxAmount0;
    uint128 maxAmount1;
}

contract MasterchefV3Connector is IFarmConnector, ILiquidityConnector {
    error Unsupported();

    function deposit(
        address target,
        address token,
        bytes memory extraData
    ) external payable override {
        // MasterchefV3 deposits use onERC721Received
        MasterchefV3ExtraData memory data =
            abi.decode(extraData, (MasterchefV3ExtraData));

        if (!data.isIncrease) {
            uint256 tokenId = IERC721Enumerable(token).tokenOfOwnerByIndex(
                address(this), data.tokenBalance
            );

            IERC721(token)
                // only deposit if its not a IncreaseLiquidity
                .safeTransferFrom(address(this), target, tokenId);
        }
    }

    function withdraw(
        address target,
        uint256, // amount
        bytes memory extraData
    ) external override {
        MasterchefV3ExtraData memory data =
            abi.decode(extraData, (MasterchefV3ExtraData));
        IMasterchefV3(target).withdraw(data.tokenId, address(this));
    }

    function claim(address target, bytes memory extraData) external override {
        MasterchefV3ExtraData memory data =
            abi.decode(extraData, (MasterchefV3ExtraData));
        IMasterchefV3(target).harvest(data.tokenId, address(this));
        if (data.maxAmount0 > 0 || data.maxAmount1 > 0) {
            INonfungiblePositionManager.CollectParams memory params =
            INonfungiblePositionManager.CollectParams({
                tokenId: data.tokenId,
                recipient: address(this),
                amount0Max: data.maxAmount0,
                amount1Max: data.maxAmount1
            });
            INonfungiblePositionManager(target).collect(params);
        }
    }

    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        MasterchefV3ExtraData memory extraData =
            abi.decode(addLiquidityData.extraData, (MasterchefV3ExtraData));

        INonfungiblePositionManager.IncreaseLiquidityParams memory params =
        INonfungiblePositionManager.IncreaseLiquidityParams({
            tokenId: extraData.tokenId,
            amount0Desired: addLiquidityData.desiredAmounts[0],
            amount1Desired: addLiquidityData.desiredAmounts[1],
            amount0Min: addLiquidityData.minAmounts[0],
            amount1Min: addLiquidityData.minAmounts[1],
            deadline: block.timestamp + 1
        });

        INonfungiblePositionManager(addLiquidityData.router).increaseLiquidity(
            params
        );
    }

    function removeLiquidity(RemoveLiquidityData memory)
        external
        pure
        override
    {
        revert Unsupported();
    }

    function swapExactTokensForTokens(SwapData memory)
        external
        payable
        override
    {
        revert Unsupported();
    }
}
