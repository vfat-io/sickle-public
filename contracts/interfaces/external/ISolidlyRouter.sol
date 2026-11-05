// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ISolidlyRouter {
    /// @dev Route struct for Solidly-style routers (Velodrome, Aerodrome, etc.)
    struct Route {
        address from;
        address to;
        bool stable;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
