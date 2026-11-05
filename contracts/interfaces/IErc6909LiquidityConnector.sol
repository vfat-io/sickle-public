// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Optional connector capability for LP positions represented by
/// ERC-6909 balances. A range ID is fungible, so its liquidity is meaningful
/// only together with the holder that owns the range shares.
/// @dev ERC-6909 does not prescribe AMM position metadata. Connectors opting
/// into this capability retain the normal INftLiquidityConnector surface for
/// ticks, pool identity, zapping and withdrawals.
interface IErc6909LiquidityConnector {
    function positionLiquidityOf(
        address positionManager,
        address holder,
        uint256 rangeId
    )
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity);
}
