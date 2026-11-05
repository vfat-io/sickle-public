// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { ILBRouter } from "contracts/interfaces/external/lfj/ILBRouter.sol";
import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";
import {
    IBinLiquidityConnector
} from "contracts/interfaces/IBinLiquidityConnector.sol";
import {
    BinAddLiquidity,
    BinRemoveLiquidity
} from "contracts/structs/BinFarmStrategyStructs.sol";

contract LFJConnector is IBinLiquidityConnector {
    error PairTokenMismatch();
    ILBRouter public immutable lbRouter;

    constructor(
        ILBRouter _lbRouter
    ) {
        lbRouter = _lbRouter;
    }

    /// @inheritdoc IBinLiquidityConnector
    function addLiquidity(
        BinAddLiquidity calldata params
    )
        external
        override
        returns (uint256[] memory depositIds, uint256[] memory liquidityMinted)
    {
        if (
            address(params.lbPair.getTokenX()) != params.tokenX
                || address(params.lbPair.getTokenY()) != params.tokenY
        ) {
            revert PairTokenMismatch();
        }
        // Approve tokens to router
        SafeTransferLib.safeApprove(params.tokenX, address(lbRouter), 0);
        SafeTransferLib.safeApprove(
            params.tokenX, address(lbRouter), params.amountX
        );
        SafeTransferLib.safeApprove(params.tokenY, address(lbRouter), 0);
        SafeTransferLib.safeApprove(
            params.tokenY, address(lbRouter), params.amountY
        );

        ILBRouter.LiquidityParameters memory liquidityParams =
            ILBRouter.LiquidityParameters({
                tokenX: IERC20(params.tokenX),
                tokenY: IERC20(params.tokenY),
                binStep: params.lbPair.getBinStep(),
                amountX: params.amountX,
                amountY: params.amountY,
                amountXMin: params.amountXMin,
                amountYMin: params.amountYMin,
                activeIdDesired: params.activeIdDesired,
                idSlippage: params.idSlippage,
                deltaIds: params.deltaIds,
                distributionX: params.distributionX,
                distributionY: params.distributionY,
                to: address(this),
                refundTo: address(this),
                deadline: block.timestamp
            });

        (,,,, depositIds, liquidityMinted) =
            lbRouter.addLiquidity(liquidityParams);

        // Reset approvals
        SafeTransferLib.safeApprove(params.tokenX, address(lbRouter), 0);
        SafeTransferLib.safeApprove(params.tokenY, address(lbRouter), 0);
    }

    /// @inheritdoc IBinLiquidityConnector
    function removeLiquidity(
        BinRemoveLiquidity calldata params
    ) external override returns (uint256 amountX, uint256 amountY) {
        if (
            address(params.lbPair.getTokenX()) != params.tokenX
                || address(params.lbPair.getTokenY()) != params.tokenY
        ) {
            revert PairTokenMismatch();
        }
        // Approve LBPair to spend LB tokens (ERC-1155 style)
        // Note: Only set approval if not already approved to avoid issues with
        // LFJ V2.2's immutable args pattern when called via delegatecall
        bool needsApproval =
            !params.lbPair.isApprovedForAll(address(this), address(lbRouter));
        if (needsApproval) {
            params.lbPair.approveForAll(address(lbRouter), true);
        }

        (amountX, amountY) = lbRouter.removeLiquidity(
            IERC20(params.tokenX),
            IERC20(params.tokenY),
            params.lbPair.getBinStep(),
            params.amountXMin,
            params.amountYMin,
            params.ids,
            params.amounts,
            address(this),
            block.timestamp
        );

        // Revoke approval
        if (needsApproval) {
            params.lbPair.approveForAll(address(lbRouter), false);
        }
    }

    /// @inheritdoc IBinLiquidityConnector
    function binStep(
        ILBPair lbPair
    ) external pure override returns (uint16) {
        return lbPair.getBinStep();
    }

    /// @inheritdoc IBinLiquidityConnector
    function activeId(
        ILBPair lbPair
    ) external view override returns (uint24) {
        return lbPair.getActiveId();
    }

    /// @inheritdoc IBinLiquidityConnector
    function binBalances(
        ILBPair lbPair,
        address account,
        uint256[] calldata ids
    ) external view override returns (uint256[] memory balances) {
        balances = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            balances[i] = lbPair.balanceOf(account, ids[i]);
        }
    }

    /// @inheritdoc IBinLiquidityConnector
    function totalBinBalance(
        ILBPair lbPair,
        address account,
        uint256[] calldata ids
    ) external view override returns (uint256 total) {
        for (uint256 i = 0; i < ids.length; i++) {
            total += lbPair.balanceOf(account, ids[i]);
        }
    }

    /// @inheritdoc IBinLiquidityConnector
    function underlyingAmounts(
        ILBPair lbPair,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external view override returns (uint256 amountX, uint256 amountY) {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 amount = amounts[i];

            // Get bin reserves
            (uint128 binReserveX, uint128 binReserveY) =
                lbPair.getBin(uint24(id));
            uint256 supply = lbPair.totalSupply(id);

            if (supply > 0) {
                // Calculate proportional share
                amountX += Math.mulDiv(uint256(binReserveX), amount, supply);
                amountY += Math.mulDiv(uint256(binReserveY), amount, supply);
            }
        }
    }
}
