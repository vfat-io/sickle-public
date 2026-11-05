// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISushiStaker {
    function stake(
        uint256 tokenId
    ) external;

    function unstake(
        uint256 tokenId
    ) external;

    function isStaked(
        uint256 tokenId
    ) external view returns (bool);

    function factory() external view returns (address);

    function getGaugeVoter() external view returns (address);

    function getStaker(
        uint256 tokenId
    ) external view returns (address);

    function getPositionInfo(
        uint256 tokenId
    )
        external
        view
        returns (
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity
        );
}
