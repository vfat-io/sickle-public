// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    PoolKey
} from "contracts/interfaces/external/uniswap/v4/types/PoolKey.sol";
import {
    PoolId
} from "contracts/interfaces/external/uniswap/v4/types/PoolId.sol";

/// @dev Mirrors Fables `LedgerTypes.RangeState`. Field order is load-bearing.
struct FablesRangeState {
    uint128 totalShares;
    uint128 totalStaked;
    uint256 accFee0X128;
    uint256 accFee1X128;
    uint256 accStaked0X128;
    uint256 accStaked1X128;
    uint128 stakedResidual0;
    uint128 stakedResidual1;
    uint64 collectionSeq;
    uint64 resetSeq;
}

/// @dev Mirrors Fables `LedgerTypes.UserPosition`. Field order is load-bearing.
struct FablesUserPosition {
    uint128 staked;
    uint128 owed0;
    uint128 owed1;
    uint256 checkpoint0X128;
    uint256 checkpoint1X128;
    uint256 stakedCheckpoint0X128;
    uint256 stakedCheckpoint1X128;
    uint256 forgone0;
    uint256 forgone1;
}

/// @notice Liquidity ledger inside a Fables v4 hook (ERC-6909 range shares).
/// @dev Positions are fungible receipts per `(poolId, tickLower, tickUpper)`,
///      not Uniswap PositionManager NFTs. `tokenId` in Sickle structs is the
///      ledger `rangeId`.
interface IFablesLedger {
    function deposit(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) external payable;

    function withdraw(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external;

    function claimFees(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        address to,
        uint16 maxFeeBps
    ) external;

    function stake(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 shares
    ) external;

    function unstake(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 shares
    ) external;

    function rangeId(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    ) external pure returns (uint256);

    function rangeKey(
        uint256 id
    )
        external
        view
        returns (PoolKey memory key, int24 tickLower, int24 tickUpper, bool set);

    function rangeState(
        uint256 id
    ) external view returns (FablesRangeState memory);

    function userPosition(
        uint256 id,
        address owner
    ) external view returns (FablesUserPosition memory);

    function balanceOf(
        address owner,
        uint256 id
    ) external view returns (uint256);

    function currentFee(
        PoolId poolId,
        bool zeroForOne
    ) external view returns (uint24);

    function paused() external view returns (bool);
}

/// @notice Newer shared hooks take an explicit gauge-weight consent bound.
/// @dev A rejected bounded stake must never retry the legacy selector.
interface IFablesWeightedLedger {
    function stake(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 shares,
        uint256 minGaugeWeight
    ) external;
}
