// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Mento v3 FPMM pool and factory (mento-core contracts/swap/FPMM.sol,
/// contracts/swap/FPMMFactory.sol).
interface IFPMM {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);

    /// @dev Reverts while the oracle rate is invalid or reserves are empty.
    /// The oracle price is token1 per token0 in whole-token units.
    function getRebalancingState()
        external
        view
        returns (
            uint256 oraclePriceNumerator,
            uint256 oraclePriceDenominator,
            uint256 reservePriceNumerator,
            uint256 reservePriceDenominator,
            bool reservePriceAboveOraclePrice,
            uint16 rebalanceThreshold,
            uint256 priceDifference
        );
}

interface IFPMMFactory {
    function isPool(
        address pool
    ) external view returns (bool);
}
