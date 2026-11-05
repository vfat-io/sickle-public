// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    PoolKey
} from "contracts/interfaces/external/uniswap/v4/types/PoolKey.sol";
import {
    PoolId
} from "contracts/interfaces/external/uniswap/v4/types/PoolId.sol";

interface IFablesPoolRegistry {
    struct PoolInfo {
        PoolKey key;
        PoolId id;
        bool active;
    }

    function poolCount() external view returns (uint256);

    function poolAt(
        uint256 index
    ) external view returns (PoolInfo memory);

    function poolById(
        PoolId id
    ) external view returns (PoolInfo memory);

    function activePools() external view returns (PoolInfo[] memory);
}
