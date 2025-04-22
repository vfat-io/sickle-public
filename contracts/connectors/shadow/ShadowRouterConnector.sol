// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ICLPool } from "contracts/interfaces/external/aerodrome/ICLPool.sol";

import { VelodromeRouterConnector } from
    "contracts/connectors/velodrome/VelodromeRouterConnector.sol";

contract ShadowRouterConnector is VelodromeRouterConnector {
    function getPoolPrice(
        address lpToken,
        uint256 baseTokenIndex,
        uint256 // quoteTokenIndex
    ) external view override returns (uint256 price) {
        address token0 = ICLPool(lpToken).token0();
        address token1 = ICLPool(lpToken).token1();

        uint256 amountOut0 = ICLPool(lpToken).getAmountOut(1e18, token0);
        if (amountOut0 > 1e18) {
            price = amountOut0;
        } else {
            uint256 amountOut1 = ICLPool(lpToken).getAmountOut(1e18, token1);
            if (amountOut1 < 1e18) {
                revert InvalidPrice();
            }
            price = 1e36 / amountOut1;
        }

        if (price == 0) {
            revert InvalidPrice();
        }

        if (baseTokenIndex == 1) {
            price = 1e36 / price;
        }
    }
}
