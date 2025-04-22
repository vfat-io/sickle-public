// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    IUniswapV3Pool,
    IUniswapV3PoolState,
    IUniswapV3PoolImmutables
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";

import { Sickle } from "contracts/Sickle.sol";
import {
    INftLiquidityConnector,
    NftPositionInfo,
    NftPoolInfo
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { INftSettingsRegistry } from
    "contracts/interfaces/INftSettingsRegistry.sol";
import {
    RewardBehavior,
    RewardConfig
} from "contracts/structs/PositionSettingsStructs.sol";
import {
    NftKey,
    NftSettings,
    ExitConfig,
    RebalanceConfig
} from "contracts/structs/NftSettingsStructs.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { TimelockAdmin } from "contracts/base/TimelockAdmin.sol";

struct PreviousNftSettings {
    IUniswapV3Pool pool;
    bool autoRebalance;
    RebalanceConfig rebalanceConfig;
    bool automateRewards;
    RewardConfig rewardConfig;
    bool autoExit;
    ExitConfig exitConfig;
}

interface IPreviousNftSettingsRegistry {
    function getNftSettings(
        NftKey memory key
    ) external view returns (PreviousNftSettings memory);
}

contract NftSettingsRegistry is TimelockAdmin, INftSettingsRegistry {
    uint256 constant MAX_SLIPPAGE_BP = 500;
    uint256 constant MAX_PRICE_IMPACT_BP = 5000;
    uint256 constant MAX_DUST_BP = 5000;
    int24 constant MAX_TICK = 887_272;
    int24 constant MIN_TICK = -MAX_TICK;

    SickleFactory public immutable factory;
    ConnectorRegistry private _connectorRegistry;

    constructor(
        SickleFactory _factory,
        ConnectorRegistry connectorRegistry,
        address timelockAdmin
    ) TimelockAdmin(timelockAdmin) {
        factory = _factory;
        _connectorRegistry = connectorRegistry;
        emit ConnectionRegistrySet(address(connectorRegistry));
    }

    mapping(bytes32 => NftSettings) settingsMap;

    /*  Timelock functions */

    function setConnectorRegistry(
        ConnectorRegistry connectorRegistry
    ) external onlyTimelockAdmin {
        _connectorRegistry = connectorRegistry;
        emit ConnectionRegistrySet(address(connectorRegistry));
    }

    /* Public functions */

    function getNftSettings(
        NftKey memory key
    ) public view returns (NftSettings memory) {
        return settingsMap[keccak256(abi.encode(key))];
    }

    function validateHarvestFor(
        NftKey memory key
    ) public view {
        NftSettings memory settings = getNftSettings(key);
        if (
            !settings.automateRewards
                || settings.rewardConfig.rewardBehavior != RewardBehavior.Harvest
        ) {
            revert AutoHarvestNotSet();
        }
    }

    function validateCompoundFor(
        NftKey memory key
    ) public view {
        NftSettings memory settings = getNftSettings(key);
        if (
            !settings.automateRewards
                || settings.rewardConfig.rewardBehavior != RewardBehavior.Compound
        ) {
            revert AutoCompoundNotSet();
        }
    }

    // Validate that a rebalanceFor meets the user requirements
    function validateRebalanceFor(
        NftKey memory key
    ) public view {
        NftSettings memory settings = getNftSettings(key);
        RebalanceConfig memory config = settings.rebalanceConfig;

        if (!settings.autoRebalance) {
            revert AutoRebalanceNotSet();
        }
        if (config.cutoffTickLow == 0) {
            revert RebalanceConfigNotSet();
        }

        INftLiquidityConnector connector = INftLiquidityConnector(
            _connectorRegistry.connectorOf(address(key.nftManager))
        );
        NftPositionInfo memory positionInfo =
            connector.positionInfo(address(key.nftManager), key.tokenId);
        NftPoolInfo memory poolInfo =
            connector.poolInfo(address(settings.pool), settings.poolId);

        if (
            poolInfo.tick
                >= positionInfo.tickLower - int24(config.bufferTicksBelow)
                && poolInfo.tick
                    < positionInfo.tickUpper + int24(config.bufferTicksAbove)
        ) {
            revert TickWithinRange();
        }
        if (
            poolInfo.tick <= config.cutoffTickLow
                || poolInfo.tick >= config.cutoffTickHigh
        ) {
            revert TickOutsideStopLossRange();
        }
    }

    function validateExitFor(
        NftKey memory key
    ) public view {
        NftSettings memory settings = getNftSettings(key);
        ExitConfig memory config = settings.exitConfig;

        if (!settings.autoExit) {
            revert AutoExitNotSet();
        }

        INftLiquidityConnector connector = INftLiquidityConnector(
            _connectorRegistry.connectorOf(address(key.nftManager))
        );
        NftPoolInfo memory poolInfo =
            connector.poolInfo(address(settings.pool), settings.poolId);

        if (
            poolInfo.tick >= config.triggerTickLow
                && poolInfo.tick < config.triggerTickHigh
        ) {
            revert TickWithinRange();
        }
    }

    /* Sickle Owner functions */

    function setNftSettings(
        INonfungiblePositionManager nftManager,
        uint256 tokenId,
        NftSettings calldata settings
    ) external {
        Sickle sickle = _getSickleByOwner(msg.sender);
        NftKey memory key =
            NftKey({ sickle: sickle, nftManager: nftManager, tokenId: tokenId });
        _setNftSettings(key, settings);
    }

    function unsetNftSettings(
        INonfungiblePositionManager nftManager,
        uint256 tokenId
    ) external {
        Sickle sickle = _getSickleByOwner(msg.sender);
        NftKey memory key =
            NftKey({ sickle: sickle, nftManager: nftManager, tokenId: tokenId });
        _unsetNftSettings(key);
    }

    function migrateNftSettings(
        IPreviousNftSettingsRegistry previousNftSettingsRegistry,
        INonfungiblePositionManager nftManager,
        uint256[] memory tokenIds
    ) external {
        Sickle sickle = _getSickleByOwner(msg.sender);

        uint256 tokenLength = tokenIds.length;
        for (uint256 i; i < tokenLength; i++) {
            NftKey memory key = NftKey({
                sickle: sickle,
                nftManager: nftManager,
                tokenId: tokenIds[i]
            });
            PreviousNftSettings memory previousSettings =
                previousNftSettingsRegistry.getNftSettings(key);
            NftSettings memory settings = NftSettings({
                pool: previousSettings.pool,
                poolId: bytes32(0), // Uniswap V4 only, not used by previous NFT
                    // settings
                autoRebalance: previousSettings.autoRebalance,
                rebalanceConfig: previousSettings.rebalanceConfig,
                automateRewards: previousSettings.automateRewards,
                rewardConfig: previousSettings.rewardConfig,
                autoExit: previousSettings.autoExit,
                exitConfig: previousSettings.exitConfig,
                extraData: ""
            });
            _setNftSettings(key, settings);
        }
    }

    /* Sickle functions */

    function setNftSettings(
        NftKey calldata key,
        NftSettings calldata settings
    ) external {
        Sickle sickle = Sickle(payable(msg.sender));

        if (key.sickle != sickle) {
            revert OnlySickle();
        }

        _setNftSettings(key, settings);
    }

    /// Transfer NFT settings from the old NFT to the new one during a
    /// rebalance.
    function transferNftSettings(
        NftKey calldata oldKey,
        NftSettings calldata settings
    ) external {
        Sickle sickle = Sickle(payable(msg.sender));

        if (oldKey.sickle != sickle) {
            revert OnlySickle();
        }

        INftLiquidityConnector connector = INftLiquidityConnector(
            _connectorRegistry.connectorOf(address(oldKey.nftManager))
        );
        uint256 newTokenId =
            connector.getTokenId(address(oldKey.nftManager), msg.sender);
        NftKey memory newKey = NftKey({
            sickle: sickle,
            nftManager: oldKey.nftManager,
            tokenId: newTokenId
        });

        if (newTokenId == oldKey.tokenId) {
            revert TokenIdUnchanged();
        }

        _unsetNftSettings(oldKey);
        _setNftSettings(newKey, settings);
    }

    /* Modifiers */

    modifier checkConfigValues(NftKey memory key, NftSettings memory settings) {
        if (address(key.nftManager) == address(0)) {
            revert InvalidNftManager();
        }
        if (settings.autoRebalance) {
            _checkRebalanceConfig(settings.rebalanceConfig);
            _checkTickWidth(key, settings);
        } else {
            if (
                settings.rebalanceConfig.cutoffTickLow != 0
                    || settings.rebalanceConfig.cutoffTickHigh != 0
            ) {
                revert AutoRebalanceNotSet();
            }
        }
        if (
            settings.rewardConfig.rewardBehavior != RewardBehavior.Harvest
                && settings.rewardConfig.harvestTokenOut != address(0)
        ) {
            revert InvalidTokenOut();
        }
        if (settings.autoExit) {
            _checkExitConfig(settings.exitConfig);
        } else {
            if (
                settings.exitConfig.triggerTickLow != 0
                    || settings.exitConfig.triggerTickHigh != 0
                    || settings.exitConfig.exitTokenOutLow != address(0)
                    || settings.exitConfig.exitTokenOutHigh != address(0)
                    || settings.exitConfig.slippageBP != 0
                    || settings.exitConfig.priceImpactBP != 0
            ) {
                revert AutoExitNotSet();
            }
        }
        _;
    }

    /* Internal */

    function _getSickleByOwner(
        address owner
    ) internal view returns (Sickle) {
        address sickle = factory.sickles(owner);
        if (sickle == address(0)) {
            revert SickleNotDeployed();
        }
        return Sickle(payable(sickle));
    }

    function _setNftSettings(
        NftKey memory key,
        NftSettings memory settings
    ) internal checkConfigValues(key, settings) {
        settingsMap[keccak256(abi.encode(key))] = settings;
        emit NftSettingsSet(key, settings);
    }

    function _unsetNftSettings(
        NftKey memory key
    ) internal {
        delete settingsMap[keccak256(abi.encode(key))];
        emit NftSettingsUnset(key);
    }

    // Check configuration parameters for errors
    function _checkRebalanceConfig(
        RebalanceConfig memory config
    ) internal pure {
        if (config.cutoffTickLow < MIN_TICK) {
            revert InvalidMinTickLow();
        }
        if (config.cutoffTickLow >= config.cutoffTickHigh) {
            revert InvalidMinMaxTickRange();
        }
        if (config.cutoffTickHigh > MAX_TICK) {
            revert InvalidMaxTickHigh();
        }
        if (
            config.bufferTicksAbove > 2 * MAX_TICK
                || config.bufferTicksAbove < 2 * MIN_TICK
        ) {
            revert InvalidBufferTicksAbove();
        }
        if (
            config.bufferTicksBelow > 2 * MAX_TICK
                || config.bufferTicksBelow < 2 * MIN_TICK
        ) {
            revert InvalidBufferTicksBelow();
        }
        if (config.slippageBP > MAX_SLIPPAGE_BP) {
            revert InvalidSlippageBP();
        }
        if (
            config.priceImpactBP > MAX_PRICE_IMPACT_BP
                || config.priceImpactBP == 0
        ) {
            revert InvalidPriceImpactBP();
        }
        if (config.dustBP > MAX_DUST_BP || config.dustBP == 0) {
            revert InvalidDustBP();
        }
        if (
            config.rewardConfig.rewardBehavior != RewardBehavior.Harvest
                && config.rewardConfig.harvestTokenOut != address(0)
        ) {
            revert InvalidTokenOut();
        }
    }

    function _checkExitConfig(
        ExitConfig memory config
    ) internal pure {
        if (config.triggerTickLow == 0 && config.triggerTickHigh == 0) {
            revert ExitTriggersNotSet();
        }
        if (
            config.triggerTickLow >= config.triggerTickHigh
                || config.triggerTickLow < MIN_TICK
                || config.triggerTickHigh > MAX_TICK
        ) {
            revert InvalidExitTriggers();
        }
        if (config.slippageBP > MAX_SLIPPAGE_BP) {
            revert InvalidSlippageBP();
        }
        if (
            config.priceImpactBP > MAX_PRICE_IMPACT_BP
                || config.priceImpactBP == 0
        ) {
            revert InvalidPriceImpactBP();
        }
    }

    function _checkTickWidth(
        NftKey memory key,
        NftSettings memory settings
    ) internal view {
        INftLiquidityConnector connector = INftLiquidityConnector(
            _connectorRegistry.connectorOf(address(key.nftManager))
        );
        NftPositionInfo memory positionInfo =
            connector.positionInfo(address(key.nftManager), key.tokenId);
        NftPoolInfo memory poolInfo =
            connector.poolInfo(address(settings.pool), settings.poolId);

        uint24 actualWidth = uint24(
            positionInfo.tickUpper - positionInfo.tickLower
        ) / poolInfo.tickSpacing;
        uint24 expectedWidth = settings.rebalanceConfig.tickSpacesBelow
            + settings.rebalanceConfig.tickSpacesAbove + 1;

        if (actualWidth != expectedWidth) {
            revert InvalidWidth(actualWidth, expectedWidth);
        }
    }
}
