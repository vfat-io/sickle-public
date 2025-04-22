// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ICurvePool } from "contracts/interfaces/external/curve/ICurvePool.sol";
import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams,
    SwapParams
} from "contracts/interfaces/ILiquidityConnector.sol";

struct CurveAddLiquidityExtraData {
    uint256 minMintAmount;
}

struct CurveSwapExtraData {
    int128 i;
    int128 j;
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract CurvePoolConnector is ILiquidityConnector {
    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external payable override {
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

    function swapExactTokensForTokens(
        SwapParams memory swap
    ) external payable override {
        CurveSwapExtraData memory extraData =
            abi.decode(swap.extraData, (CurveSwapExtraData));

        ICurvePool(swap.router).exchange(
            extraData.i, extraData.j, swap.amountIn, swap.minAmountOut
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
}
