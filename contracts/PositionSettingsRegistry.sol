// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { TimelockAdmin } from "contracts/base/TimelockAdmin.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import {
    PositionKey,
    RewardBehavior,
    RewardConfig,
    ExitConfig,
    PositionSettings
} from "contracts/structs/PositionSettingsStructs.sol";
import { ILiquidityConnector } from
    "contracts/interfaces/ILiquidityConnector.sol";
import { IPositionSettingsRegistry } from
    "contracts/interfaces/IPositionSettingsRegistry.sol";

struct PreviousExitConfig {
    uint256 triggerPriceHigh;
    uint256 triggerPriceLow;
    uint256 triggerReserves0;
    uint256 triggerReserves1;
    address exitTokenOutLow;
    address exitTokenOutHigh;
    uint256 priceImpactBP;
    uint256 slippageBP;
}

struct PreviousPositionSettings {
    address pair;
    address router;
    bool automateRewards;
    RewardConfig rewardConfig;
    bool autoExit;
    PreviousExitConfig exitConfig;
}

interface IPreviousSettingsRegistry {
    function getPositionSettings(
        PositionKey calldata key
    ) external view returns (PreviousPositionSettings memory);
}

contract PositionSettingsRegistry is
    TimelockAdmin,
    IPositionSettingsRegistry
{
    uint256 constant MAX_SLIPPAGE_BP = 500;
    uint256 constant MAX_PRICE_IMPACT_BP = 5000;

    SickleFactory public immutable factory;
    ConnectorRegistry private _connectorRegistry;

    mapping(bytes32 => PositionSettings) positionSettingsMap;

    constructor(
        SickleFactory _factory,
        ConnectorRegistry connectorRegistry,
        address timelockAdmin
    ) TimelockAdmin(timelockAdmin) {
        factory = _factory;
        _connectorRegistry = connectorRegistry;
        emit ConnectionRegistrySet(address(connectorRegistry));
    }

    /* Timelock functions */

    function setConnectorRegistry(
        ConnectorRegistry connectorRegistry
    ) external onlyTimelockAdmin {
        _connectorRegistry = connectorRegistry;
        emit ConnectionRegistrySet(address(connectorRegistry));
    }

    /* Public functions */

    function getPositionSettings(
        PositionKey calldata key
    ) public view returns (PositionSettings memory) {
        bytes32 keyHash = keccak256(abi.encode(key));
        return positionSettingsMap[keyHash];
    }

    /* Owner functions */

    function setPositionSettings(
        Farm calldata farm,
        PositionSettings calldata settings
    ) external checkPositionSettings(farm.stakingContract, settings) {
        PositionKey memory key = PositionKey({
            sickle: _getSickleByOwner(msg.sender),
            stakingContract: farm.stakingContract,
            poolIndex: farm.poolIndex
        });
        bytes32 keyHash = keccak256(abi.encode(key));
        positionSettingsMap[keyHash] = settings;
        emit PositionSettingsSet(key, settings);
    }

    /* Sickle (delegatecall) functions */

    function setPositionSettings(
        PositionKey calldata key,
        PositionSettings calldata settings
    ) external checkPositionSettings(key.stakingContract, settings) {
        Sickle sickle = Sickle(payable(msg.sender));
        if (key.sickle != sickle) {
            revert OnlySickle();
        }
        bytes32 keyHash = keccak256(abi.encode(key));
        positionSettingsMap[keyHash] = settings;
        emit PositionSettingsSet(key, settings);
    }

    // Used to set reward behavior (but not auto-exit) for multiple positions
    function setMultiplePositionSettings(
        Farm[] calldata farms,
        RewardConfig calldata rewardConfig
    ) public checkRewardConfig(rewardConfig) {
        Sickle sickle = _getSickleByOwner(msg.sender);
        PositionKey memory key;
        for (uint256 i; i < farms.length; i++) {
            key = PositionKey({
                sickle: sickle,
                stakingContract: farms[i].stakingContract,
                poolIndex: farms[i].poolIndex
            });
            bytes32 keyHash = keccak256(abi.encode(key));
            positionSettingsMap[keyHash].automateRewards = true;
            positionSettingsMap[keyHash].rewardConfig = rewardConfig;
            emit PositionSettingsSet(key, positionSettingsMap[keyHash]);
        }
    }

    function migratePositionSettings(
        IPreviousSettingsRegistry previousPositionSettings,
        PositionKey[] calldata keys
    ) external {
        Sickle sickle = _getSickleByOwner(msg.sender);
        for (uint256 i; i < keys.length; i++) {
            if (keys[i].sickle != sickle) {
                revert OnlySickle();
            }
            PreviousPositionSettings memory previousSettings =
                previousPositionSettings.getPositionSettings(keys[i]);
            PositionSettings memory settings = PositionSettings({
                pool: previousSettings.pair,
                router: previousSettings.router,
                automateRewards: previousSettings.automateRewards,
                rewardConfig: previousSettings.rewardConfig,
                autoExit: previousSettings.autoExit,
                exitConfig: ExitConfig({
                    baseTokenIndex: 0,
                    quoteTokenIndex: 1,
                    triggerPriceLow: previousSettings.exitConfig.triggerPriceLow,
                    exitTokenOutLow: previousSettings.exitConfig.exitTokenOutLow,
                    triggerPriceHigh: previousSettings.exitConfig.triggerPriceHigh,
                    exitTokenOutHigh: previousSettings.exitConfig.exitTokenOutHigh,
                    triggerReservesLow: new uint256[](2),
                    triggerReservesTokensOut: new address[](2),
                    priceImpactBP: previousSettings.exitConfig.priceImpactBP,
                    slippageBP: previousSettings.exitConfig.slippageBP
                }),
                extraData: ""
            });
            settings.exitConfig.triggerReservesLow[0] =
                previousSettings.exitConfig.triggerReserves0;
            settings.exitConfig.triggerReservesLow[1] =
                previousSettings.exitConfig.triggerReserves1;
            settings.exitConfig.triggerReservesTokensOut[0] =
                previousSettings.exitConfig.exitTokenOutLow;
            settings.exitConfig.triggerReservesTokensOut[1] =
                previousSettings.exitConfig.exitTokenOutHigh;
            bytes32 keyHash = keccak256(abi.encode(keys[i]));
            positionSettingsMap[keyHash] = settings;
            emit PositionSettingsSet(keys[i], settings);
        }
    }

    function validateHarvestFor(
        PositionKey calldata key
    ) public view {
        PositionSettings memory settings = getPositionSettings(key);
        if (
            !settings.automateRewards
                || settings.rewardConfig.rewardBehavior != RewardBehavior.Harvest
        ) {
            revert AutoHarvestNotSet();
        }
    }

    function validateCompoundFor(
        PositionKey calldata key
    ) public view {
        PositionSettings memory settings = getPositionSettings(key);
        if (
            !settings.automateRewards
                || settings.rewardConfig.rewardBehavior != RewardBehavior.Compound
        ) {
            revert AutoCompoundNotSet();
        }
    }

    function validateExitFor(
        PositionKey calldata key
    ) public view {
        PositionSettings memory settings = getPositionSettings(key);
        ExitConfig memory config = settings.exitConfig;

        if (!settings.autoExit) {
            revert AutoExitNotSet();
        }

        ILiquidityConnector connector = ILiquidityConnector(
            _connectorRegistry.connectorOf(address(settings.router))
        );
        uint256 price = connector.getPoolPrice(
            address(settings.pool),
            config.baseTokenIndex,
            config.quoteTokenIndex
        );

        bool priceBelowRange = price < config.triggerPriceLow;

        bool priceAboveRange = price > config.triggerPriceHigh;

        bool reservesBelowRange = false;
        if (config.triggerReservesLow.length > 0) {
            uint256[] memory reserves =
                connector.getReserves(address(settings.pool));

            for (uint256 i; i < config.triggerReservesLow.length; i++) {
                if (reserves[i] < config.triggerReservesLow[i]) {
                    reservesBelowRange = true;
                    break;
                }
            }
        }

        if (!priceBelowRange && !priceAboveRange && !reservesBelowRange) {
            revert ConditionsNotMet();
        }
    }

    /* Modifiers */

    modifier checkPositionSettings(
        address stakingContract,
        PositionSettings memory settings
    ) {
        if (stakingContract == address(0)) {
            revert InvalidStakingContract();
        }
        if (settings.automateRewards) {
            _checkRewardConfig(settings.rewardConfig);
        } else {
            if (
                settings.rewardConfig.rewardBehavior != RewardBehavior.None
                    || settings.rewardConfig.harvestTokenOut != address(0)
            ) {
                revert NonZeroRewardConfig();
            }
        }
        if (settings.autoExit) {
            _checkExitConfig(settings);
        } else {
            if (
                settings.exitConfig.triggerPriceLow != 0
                    || settings.exitConfig.exitTokenOutLow != address(0)
                    || settings.exitConfig.triggerPriceHigh != 0
                    || settings.exitConfig.exitTokenOutHigh != address(0)
                    || settings.exitConfig.slippageBP != 0
                    || settings.exitConfig.priceImpactBP != 0
                    || settings.exitConfig.triggerReservesLow.length > 0
                    || settings.exitConfig.triggerReservesTokensOut.length > 0
                    || settings.exitConfig.baseTokenIndex != 0
                    || settings.exitConfig.quoteTokenIndex != 0
            ) {
                revert NonZeroExitConfig();
            }
        }
        _;
    }

    modifier checkRewardConfig(
        RewardConfig memory rewardConfig
    ) {
        _checkRewardConfig(rewardConfig);
        _;
    }

    /* Internal */

    function _checkRewardConfig(
        RewardConfig memory rewardConfig
    ) private pure {
        if (rewardConfig.rewardBehavior == RewardBehavior.None) {
            revert RewardBehaviorNotSet();
        }
        if (
            rewardConfig.rewardBehavior == RewardBehavior.Compound
                && rewardConfig.harvestTokenOut != address(0)
        ) {
            revert InvalidTokenOut();
        }
    }

    function _checkExitConfig(
        PositionSettings memory settings
    ) private view {
        if (settings.pool == address(0)) {
            revert InvalidPool();
        }
        if (settings.router == address(0)) {
            revert InvalidRouter();
        }
        if (
            settings.exitConfig.triggerPriceLow == 0
                && settings.exitConfig.triggerPriceHigh == 0
        ) {
            revert ExitTriggersNotSet();
        }
        if (
            settings.exitConfig.triggerPriceLow
                >= settings.exitConfig.triggerPriceHigh
        ) {
            revert InvalidExitTriggers();
        }
        if (settings.exitConfig.slippageBP > MAX_SLIPPAGE_BP) {
            revert InvalidSlippageBP();
        }
        if (
            settings.exitConfig.priceImpactBP > MAX_PRICE_IMPACT_BP
                || settings.exitConfig.priceImpactBP == 0
        ) {
            revert InvalidPriceImpactBP();
        }

        if (
            settings.exitConfig.triggerReservesLow.length
                != settings.exitConfig.triggerReservesTokensOut.length
        ) {
            revert InvalidTriggerReserves();
        }
        ILiquidityConnector connector = ILiquidityConnector(
            _connectorRegistry.connectorOf(address(settings.router))
        );
        uint256[] memory reserves =
            connector.getReserves(address(settings.pool));
        if (
            settings.exitConfig.baseTokenIndex >= reserves.length
                || settings.exitConfig.quoteTokenIndex >= reserves.length
                || settings.exitConfig.baseTokenIndex
                    == settings.exitConfig.quoteTokenIndex
        ) {
            revert InvalidTokenIndices();
        }
        if (settings.exitConfig.triggerReservesLow.length > 0) {
            if (
                reserves.length != settings.exitConfig.triggerReservesLow.length
            ) {
                revert InvalidTriggerReserves();
            }
        }
    }

    function _getSickleByOwner(
        address owner
    ) private view returns (Sickle) {
        address sickle = factory.sickles(owner);
        if (sickle == address(0)) {
            revert SickleNotDeployed();
        }
        return Sickle(payable(sickle));
    }
}
