// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ICurvePool } from "contracts/interfaces/external/curve/ICurvePool.sol";
import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/interfaces/ILiquidityConnector.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct CurveAddLiquidityExtraData {
    uint256 minMintAmount;
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract CurvePoolConnector is ILiquidityConnector, IFarmConnector {
    error NotSupported();

    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external override {
        CurveAddLiquidityExtraData memory extraData = abi.decode(
            addLiquidityParams.extraData, (CurveAddLiquidityExtraData)
        );

        ICurvePool(addLiquidityParams.router).add_liquidity(
            addLiquidityParams.desiredAmounts, extraData.minMintAmount
        );
    }

    function removeLiquidity(
        RemoveLiquidityParams memory removeLiquidityParams
    ) external override {
        ICurvePool(removeLiquidityParams.router).remove_liquidity(
            removeLiquidityParams.lpAmountIn,
            removeLiquidityParams.minAmountsOut
        );
    }

    function getPoolPrice(
        address lpToken,
        uint256 baseTokenIndex,
        uint256 quoteTokenIndex
    ) external view override returns (uint256 price) {
        address baseToken = ICurvePool(lpToken).coins(baseTokenIndex);
        uint256 baseTokenDecimals = IERC20Decimals(baseToken).decimals();
        address quoteToken = ICurvePool(lpToken).coins(quoteTokenIndex);
        uint256 quoteTokenDecimals = IERC20Decimals(quoteToken).decimals();

        uint256 amountOut0 = ICurvePool(lpToken).get_dy(
            int128(uint128(baseTokenIndex)),
            int128(uint128(quoteTokenIndex)),
            10 ** baseTokenDecimals
        );

        // We swap e.g. 1e18 DAI for USDC. This will return 1e6 USDC.
        // The price is 1e-12 USDC wei for wei or 1e18 normalized (1e6 USDC per
        // 1e18 DAI, price is 1e18).
        // We swap e.g. 1e6 USDC for DAI. This will return 1e12 DAI.
        // The price is 1e12 DAI wei for wei or 1e18 normalized (1e18 DAI per
        // 1e6 USDC, price is 1e18).
        if (amountOut0 > 0) {
            price = amountOut0 * 10 ** (18 - quoteTokenDecimals);
        } else {
            // e.g. 1e18 of base token is < 1 wei of quote token
            uint256 amountOut1 = ICurvePool(lpToken).get_dy(
                int128(uint128(quoteTokenIndex)),
                int128(uint128(baseTokenIndex)),
                10 ** quoteTokenDecimals
            );
            if (amountOut1 == 0) {
                revert InvalidPrice();
            }
            price = 1e36 / (amountOut1 * 10 ** (18 - baseTokenDecimals));
        }

        if (price == 0) {
            revert InvalidPrice();
        }
    }

    function getReserves(
        address lpToken
    ) external view override returns (uint256[] memory reserves) {
        reserves = ICurvePool(lpToken).get_balances();
    }

    function getTokens(
        address lpToken
    ) external view override returns (address[] memory tokens) {
        tokens = new address[](ICurvePool(lpToken).N_COINS());
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i] = ICurvePool(lpToken).coins(i);
        }
    }

    // IFarmConnector implementation - no-op for pools without gauges
    // LP tokens stay in the caller's wallet (Sickle)

    function deposit(
        Farm calldata, // farm
        address, // token
        bytes memory // _extraData
    ) external pure override {
        // No-op: LP tokens stay in the caller's wallet
    }

    function withdraw(
        Farm calldata, // farm
        uint256, // amount
        bytes memory // _extraData
    ) external pure override {
        // No-op: LP tokens are already in the caller's wallet
    }

    function claim(
        Farm calldata, // farm
        bytes memory // extraData
    ) external pure override {
        // No-op: No rewards to claim for pools without gauges
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        // Return the LP token balance directly from the pool
        return IERC20(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata, // farm
        address, // user
        address[] calldata rewardTokens
    ) external pure override returns (uint256[] memory) {
        // No rewards for pools without gauges
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        return rewards;
    }

    function isStaked(
        Farm calldata, // farm
        address // user
    ) external pure override returns (bool) {
        // LP tokens are held but not staked
        return false;
    }
}
