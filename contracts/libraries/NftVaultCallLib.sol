// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BPS_BASIS } from "contracts/base/Constants.sol";
import { NftFarmStrategy } from "contracts/strategies/NftFarmStrategy.sol";
import {
    NftPosition,
    NftDeposit,
    NftIncrease,
    NftHarvest,
    NftWithdraw
} from "contracts/structs/NftFarmStrategyStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import { NftSettings } from "contracts/structs/NftSettingsStructs.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {
    Pool,
    NftAddLiquidity,
    NftRemoveLiquidity
} from "contracts/structs/NftLiquidityStructs.sol";
import { NftZapIn, NftZapOut } from "contracts/structs/NftZapStructs.sol";
import { SwapParams } from "contracts/structs/SwapStructs.sol";

/// @dev Builds the large nested ABI-encoded structs for NftFarmStrategy calls
/// inside this library so the heavy memory structs never cross the ABI
/// boundary back into the vault. Each function performs the strategy call
/// itself; only scalars and small arrays cross the delegatecall boundary.
library NftVaultCallLib {
    /// @dev Flat bag of scalar increase inputs. Kept single-level (value types
    /// plus two byte/array members) so it stays cheap to ABI-encode across the
    /// delegatecall boundary; the heavy nested NftIncrease is built in-library.
    struct IncreaseArgs {
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        int24 tickLower;
        int24 tickUpper;
        uint24 fee;
        uint24 slippageBps;
        bool inPlace;
        bytes addLiquidityExtraData;
        address[] rewardTokens;
        address[] sweepTokens;
    }

    function increase(
        NftFarmStrategy nftFarmStrategy,
        NftPosition memory position,
        IncreaseArgs memory args
    ) external {
        address[] memory tokensIn = new address[](2);
        tokensIn[0] = args.token0;
        tokensIn[1] = args.token1;

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = args.amount0;
        amountsIn[1] = args.amount1;

        NftIncrease memory params = NftIncrease({
            tokensIn: tokensIn,
            amountsIn: amountsIn,
            zap: NftZapIn({
                swaps: new SwapParams[](0),
                addLiquidityParams: NftAddLiquidity({
                    nft: position.nft,
                    tokenId: position.tokenId,
                    pool: Pool({
                        token0: args.token0,
                        token1: args.token1,
                        fee: args.fee
                    }),
                    tickLower: args.tickLower,
                    tickUpper: args.tickUpper,
                    amount0Desired: args.amount0,
                    amount1Desired: args.amount1,
                    amount0Min: _withSlippage(args.amount0, args.slippageBps),
                    amount1Min: _withSlippage(args.amount1, args.slippageBps),
                    extraData: args.addLiquidityExtraData
                })
            }),
            extraData: ""
        });

        nftFarmStrategy.increase(
            position,
            _harvest(args.rewardTokens),
            params,
            args.inPlace,
            args.sweepTokens
        );
    }

    /// @dev Flat bag of scalar deposit inputs, mirroring {IncreaseArgs}: the
    /// heavy nested NftDeposit is built in-library so it never crosses the
    /// delegatecall boundary back into the size-critical vault. The vault's own
    /// constants (token0/token1/fee/nft) make the struct, so there is nothing
    /// to validate — it cannot be malformed.
    struct DepositArgs {
        Farm farm;
        INonfungiblePositionManager nft;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint256 amount0Min;
        uint256 amount1Min;
        bytes addLiquidityExtraData;
        address[] sweepTokens;
    }

    function deposit(
        NftFarmStrategy nftFarmStrategy,
        DepositArgs memory args,
        NftSettings calldata settings,
        address automation
    ) external {
        nftFarmStrategy.deposit(
            _depositParams(args),
            settings,
            args.sweepTokens,
            automation,
            bytes32(0)
        );
    }

    function _depositParams(
        DepositArgs memory args
    ) private pure returns (NftDeposit memory params) {
        address[] memory tokensIn = new address[](2);
        tokensIn[0] = args.token0;
        tokensIn[1] = args.token1;

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = args.amount0;
        amountsIn[1] = args.amount1;

        NftIncrease memory increase = NftIncrease({
            tokensIn: tokensIn,
            amountsIn: amountsIn,
            zap: NftZapIn({
                swaps: new SwapParams[](0),
                addLiquidityParams: NftAddLiquidity({
                    nft: args.nft,
                    tokenId: 0,
                    pool: Pool({
                        token0: args.token0,
                        token1: args.token1,
                        fee: args.fee
                    }),
                    tickLower: args.tickLower,
                    tickUpper: args.tickUpper,
                    amount0Desired: args.amount0,
                    amount1Desired: args.amount1,
                    amount0Min: args.amount0Min,
                    amount1Min: args.amount1Min,
                    extraData: args.addLiquidityExtraData
                })
            }),
            extraData: ""
        });

        params =
            NftDeposit({ farm: args.farm, nft: args.nft, increase: increase });
    }

    function withdraw(
        NftFarmStrategy nftFarmStrategy,
        NftPosition memory position,
        uint128 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes memory removeLiquidityExtraData,
        address[] memory sweepTokens
    ) external {
        nftFarmStrategy.withdraw(
            position,
            _withdrawParams(
                position,
                liquidity,
                minAmount0,
                minAmount1,
                amount0Max,
                amount1Max,
                removeLiquidityExtraData,
                sweepTokens
            ),
            sweepTokens
        );
    }

    function decrease(
        NftFarmStrategy nftFarmStrategy,
        NftPosition memory position,
        uint128 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes memory removeLiquidityExtraData,
        bool inPlace,
        address[] memory rewardTokens,
        address[] memory sweepTokens
    ) external {
        nftFarmStrategy.decrease(
            position,
            _harvest(rewardTokens),
            _withdrawParams(
                position,
                liquidity,
                minAmount0,
                minAmount1,
                amount0Max,
                amount1Max,
                removeLiquidityExtraData,
                sweepTokens
            ),
            inPlace,
            sweepTokens
        );
    }

    function harvest(
        NftFarmStrategy nftFarmStrategy,
        NftPosition memory position,
        address[] memory rewardTokens
    ) external {
        nftFarmStrategy.harvest(position, _harvest(rewardTokens));
    }

    function _withdrawParams(
        NftPosition memory position,
        uint128 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes memory removeLiquidityExtraData,
        address[] memory sweepTokens
    ) private pure returns (NftWithdraw memory params) {
        params = NftWithdraw({
            zap: NftZapOut({
                removeLiquidityParams: NftRemoveLiquidity({
                    nft: position.nft,
                    tokenId: position.tokenId,
                    liquidity: liquidity,
                    amount0Min: minAmount0,
                    amount1Min: minAmount1,
                    amount0Max: amount0Max,
                    amount1Max: amount1Max,
                    extraData: removeLiquidityExtraData
                }),
                swaps: new SwapParams[](0)
            }),
            tokensOut: sweepTokens,
            extraData: ""
        });
    }

    /// @dev Builds an NftHarvest. When `rewardTokens` is empty this is the
    /// empty-harvest used inside increase/decrease; when it carries the reward
    /// token it is the reward harvest used by the harvest vault.
    function _harvest(
        address[] memory rewardTokens
    ) private pure returns (NftHarvest memory params) {
        params.harvest.rewardTokens = rewardTokens;
        params.swaps = new SwapParams[](0);
        params.outputTokens = new address[](0);
        params.sweepTokens = rewardTokens;
    }

    function _withSlippage(
        uint256 amount,
        uint24 slippageBps
    ) private pure returns (uint256) {
        return amount * (BPS_BASIS - slippageBps) / BPS_BASIS;
    }
}
