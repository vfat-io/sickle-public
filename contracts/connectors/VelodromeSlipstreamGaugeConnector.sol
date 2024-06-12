// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import {
    ILiquidityConnector,
    AddLiquidityData,
    RemoveLiquidityData,
    SwapData
} from "contracts/interfaces/ILiquidityConnector.sol";
import { ICLGauge } from "contracts/interfaces/external/aerodrome/ICLGauge.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Enumerable } from
    "@openzeppelin/contracts/interfaces/IERC721Enumerable.sol";

struct VelodromeSlipstreamGaugeDepositExtraData {
    uint256 tokenId;
    bool isIncrease;
    // User's existing NFT balance in the Sickle, typically 0
    uint256 tokenBalance;
}

struct VelodromeSlipstreamGaugeClaimExtraData {
    uint256 tokenId;
}

struct VelodromeSlipstreamGaugeWithdrawExtraData {
    uint256 tokenId;
    bool isDecrease;
    uint128 liquidity;
}

contract VelodromeSlipstreamGaugeConnector is
    IFarmConnector,
    ILiquidityConnector
{
    error Unsupported();

    function deposit(
        address target,
        address token,
        bytes memory extraData
    ) external payable override {
        VelodromeSlipstreamGaugeDepositExtraData memory data =
            abi.decode(extraData, (VelodromeSlipstreamGaugeDepositExtraData));
        if (!data.isIncrease) {
            uint256 tokenId = IERC721Enumerable(token).tokenOfOwnerByIndex(
                address(this), data.tokenBalance
            );

            IERC721(token).approve(target, tokenId);
            ICLGauge(target).deposit(tokenId);
        }
    }

    function withdraw(
        address target,
        uint256, // amount
        bytes memory extraData
    ) external override {
        VelodromeSlipstreamGaugeWithdrawExtraData memory data =
            abi.decode(extraData, (VelodromeSlipstreamGaugeWithdrawExtraData));
        if (!data.isDecrease) {
            ICLGauge(target).withdraw(data.tokenId);
        }
    }

    function claim(address target, bytes memory extraData) external override {
        VelodromeSlipstreamGaugeClaimExtraData memory data =
            abi.decode(extraData, (VelodromeSlipstreamGaugeClaimExtraData));
        ICLGauge(target).getReward(data.tokenId);
    }

    function addLiquidity(AddLiquidityData memory addLiquidityData)
        external
        payable
        override
    {
        VelodromeSlipstreamGaugeDepositExtraData memory data = abi.decode(
            addLiquidityData.extraData,
            (VelodromeSlipstreamGaugeDepositExtraData)
        );
        ICLGauge(addLiquidityData.router).increaseStakedLiquidity(
            data.tokenId,
            addLiquidityData.desiredAmounts[0],
            addLiquidityData.desiredAmounts[1],
            addLiquidityData.minAmounts[0],
            addLiquidityData.minAmounts[1],
            block.timestamp
        );
    }

    function removeLiquidity(RemoveLiquidityData memory removeLiquidityData)
        external
        override
    {
        VelodromeSlipstreamGaugeWithdrawExtraData memory data = abi.decode(
            removeLiquidityData.extraData,
            (VelodromeSlipstreamGaugeWithdrawExtraData)
        );
        ICLGauge(removeLiquidityData.router).decreaseStakedLiquidity(
            data.tokenId,
            data.liquidity,
            removeLiquidityData.minAmountsOut[0],
            removeLiquidityData.minAmountsOut[1],
            block.timestamp
        );
    }

    function swapExactTokensForTokens(SwapData memory)
        external
        payable
        override
    {
        revert Unsupported();
    }
}
