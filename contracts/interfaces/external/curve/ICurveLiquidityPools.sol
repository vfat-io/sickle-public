// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Curve liquidity entry points by coin-array ABI. Return values differ between
// pool generations (legacy pools return nothing), so none are declared and
// return data is never decoded. `add_liquidity` is payable for pools with a
// native ETH coin; every other pool receives zero value.

interface ICurveDynamicArrayPool {
    function add_liquidity(
        uint256[] calldata _amounts,
        uint256 _min_mint_amount
    ) external payable;
    function remove_liquidity(
        uint256 _burn_amount,
        uint256[] calldata _min_amounts
    ) external;
}

interface ICurveTwoCoinPool {
    function add_liquidity(
        uint256[2] calldata _amounts,
        uint256 _min_mint_amount
    ) external payable;
    function remove_liquidity(
        uint256 _burn_amount,
        uint256[2] calldata _min_amounts
    ) external;
}

interface ICurveThreeCoinPool {
    function add_liquidity(
        uint256[3] calldata _amounts,
        uint256 _min_mint_amount
    ) external payable;
    function remove_liquidity(
        uint256 _burn_amount,
        uint256[3] calldata _min_amounts
    ) external;
}

interface ICurveFourCoinPool {
    function add_liquidity(
        uint256[4] calldata _amounts,
        uint256 _min_mint_amount
    ) external payable;
    function remove_liquidity(
        uint256 _burn_amount,
        uint256[4] calldata _min_amounts
    ) external;
}

/// @dev Crypto pools index quotes by uint256; stable pools use int128
/// (`ICurvePool.get_dy`).
interface ICurveCryptoPool {
    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256);
}

interface ICurveTwoCoinLendingPool {
    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 minimum,
        bool useUnderlying
    ) external;
    function remove_liquidity(
        uint256 amount,
        uint256[2] calldata minimums,
        bool useUnderlying
    ) external;
}

interface ICurveThreeCoinLendingPool {
    function add_liquidity(
        uint256[3] calldata amounts,
        uint256 minimum,
        bool useUnderlying
    ) external;
    function remove_liquidity(
        uint256 amount,
        uint256[3] calldata minimums,
        bool useUnderlying
    ) external;
}

interface ICurveFourCoinLendingPool {
    function add_liquidity(
        uint256[4] calldata amounts,
        uint256 minimum,
        bool useUnderlying
    ) external;
    function remove_liquidity(
        uint256 amount,
        uint256[4] calldata minimums,
        bool useUnderlying
    ) external;
}

interface ICurveLendingPool {
    function get_dy_underlying(
        int128 i,
        int128 j,
        uint256 amount
    ) external view returns (uint256);
}
