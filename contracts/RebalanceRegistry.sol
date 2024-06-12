// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { Sickle } from "contracts/Sickle.sol";
import {
    IRebalanceRegistry,
    RebalanceKey,
    RebalanceConfig
} from "./interfaces/IRebalanceRegistry.sol";

abstract contract RebalanceRegistry is IRebalanceRegistry {
    error InvalidTickRange();
    error InvalidMinMaxTickRange();
    error InvalidTickLow();
    error InvalidTickHigh();
    error InvalidSlippageBP();
    error InvalidMinTickLow();
    error InvalidMaxTickHigh();
    error OnlySickle();

    event RebalanceConfigSet(RebalanceKey key, RebalanceConfig config);
    event RebalanceConfigUnset(RebalanceKey key);

    uint256 constant MAX_SLIPPAGE_BP = 500;
    int24 constant MIN_TICK = -887_272;
    int24 constant MAX_TICK = 887_272;
    mapping(bytes32 => RebalanceConfig) public rebalanceConfigs;

    function getRebalanceConfig(RebalanceKey memory key)
        public
        view
        returns (RebalanceConfig memory)
    {
        return rebalanceConfigs[keccak256(abi.encode(key))];
    }

    function _set_rebalance_config(
        RebalanceKey memory key,
        RebalanceConfig calldata config
    ) internal checkConfigValues(config) {
        rebalanceConfigs[keccak256(abi.encode(key))] = config;
        emit RebalanceConfigSet(key, config);
    }

    function _unset_rebalance_config(RebalanceKey memory key) internal {
        delete rebalanceConfigs[keccak256(abi.encode(key))];
        emit RebalanceConfigUnset(key);
    }

    function resetRebalanceConfig(
        RebalanceKey calldata oldKey,
        RebalanceKey calldata newKey,
        RebalanceConfig calldata config
    ) external {
        Sickle sickle = Sickle(payable(msg.sender));

        if (oldKey.sickle != sickle || newKey.sickle != sickle) {
            revert OnlySickle();
        }

        _unset_rebalance_config(oldKey);

        _set_rebalance_config(newKey, config);
    }

    modifier checkConfigValues(RebalanceConfig calldata config) {
        if (config.tickLow < MIN_TICK || config.tickLow > MAX_TICK) {
            revert InvalidTickLow();
        }
        if (config.tickHigh < MIN_TICK || config.tickHigh > MAX_TICK) {
            revert InvalidTickHigh();
        }
        if (config.tickLow >= config.tickHigh) {
            revert InvalidTickRange();
        }
        if (config.minTickLow < MIN_TICK || config.minTickLow > MAX_TICK) {
            revert InvalidMinTickLow();
        }
        if (config.maxTickHigh < MIN_TICK || config.maxTickHigh > MAX_TICK) {
            revert InvalidMaxTickHigh();
        }
        if (config.minTickLow >= config.maxTickHigh) {
            revert InvalidMinMaxTickRange();
        }
        if (config.slippageBP > MAX_SLIPPAGE_BP) {
            revert InvalidSlippageBP();
        }
        _;
    }
}
