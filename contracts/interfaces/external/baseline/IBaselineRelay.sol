// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IBaselineRelay {
    function reserve(
        address bToken
    ) external view returns (address);

    function hasHook(
        address bToken
    ) external view returns (bool);

    function poolKey(
        address bToken
    )
        external
        view
        returns (
            address currency0,
            address currency1,
            uint24 fee,
            int24 tickSpacing,
            address hooks
        );

    function buyTokensExactOut(
        address bToken,
        uint256 amountOut,
        uint256 maxReservesIn
    ) external payable returns (uint256 reservesIn);

    function sellTokensExactIn(
        address bToken,
        uint256 amountIn,
        uint256 minReservesOut
    ) external returns (uint256 reservesOut);
}
