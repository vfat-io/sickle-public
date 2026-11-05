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

/// @notice The `ExitConfig` shape used before the scalar reserve triggers
/// became the `triggerReservesLow` array (April 2025), and the settings struct
/// wrapping it.
/// @dev Reached only by the opt-in `migratePositionSettings`. NOT the shape the
/// `previousRegistry` read-through targets: every registry generation still
/// holding live settings was deployed after that change.
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

    /// @notice Registry this one replaces, read through on a local miss so a
    /// redeploy does not strand existing per-position settings.
    /// @dev Zero on chains with no predecessor, which disables the fallback.
    /// Typed as `IPositionSettingsRegistry`, not a frozen copy of some older
    /// struct: the predecessor answers in whatever shape it was built with,
    /// and `getPositionSettings` is itself public and self-falling-back, so a
    /// predecessor that needs to bridge an older layout does that internally,
    /// in bytecode that is already deployed. Point this at the chain's CURRENT
    /// registry and generations chain recursively; point it at an older one
    /// and you skip whatever that chain's current registry was bridging.
    /// This registry never writes to its predecessor: every write lands
    /// locally, so a position migrates itself the first time it is written.
    IPositionSettingsRegistry public immutable previousRegistry;

    ConnectorRegistry private _connectorRegistry;

    mapping(bytes32 => PositionSettings) positionSettingsMap;

    /// @notice Keys this registry answers for itself, suppressing the
    /// `previousRegistry` fallback. Set by every local write.
    /// @dev A tombstone is required because an all-default `PositionSettings`
    /// is a legal write — `checkPositionSettings` permits it, and it is how a
    /// user turns automation off — and it stores as an empty struct. Emptiness
    /// therefore cannot be the discriminator: without this flag a
    /// deliberately-disabled position would read through and come back
    /// enabled.
    mapping(bytes32 => bool) public overridesPrevious;

    constructor(
        SickleFactory _factory,
        ConnectorRegistry connectorRegistry,
        address timelockAdmin,
        IPositionSettingsRegistry _previousRegistry
    ) TimelockAdmin(timelockAdmin) {
        if (address(_previousRegistry) != address(0)) {
            _checkPreviousRegistry(_previousRegistry);
        }
        factory = _factory;
        previousRegistry = _previousRegistry;
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

    /// @notice Settings for `key`, falling back to `previousRegistry` for
    /// positions that have never been written here.
    /// @dev Public and inline on purpose: the predecessor's own
    /// `getPositionSettings` falls back the same way, so a lookup walks the
    /// whole ancestry rather than a single hop.
    function getPositionSettings(
        PositionKey calldata key
    ) public view returns (PositionSettings memory) {
        bytes32 keyHash = keccak256(abi.encode(key));
        if (
            overridesPrevious[keyHash]
                || address(previousRegistry) == address(0)
        ) {
            return positionSettingsMap[keyHash];
        }
        return previousRegistry.getPositionSettings(key);
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
        overridesPrevious[keyHash] = true;
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
        overridesPrevious[keyHash] = true;
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
            _materializePrevious(key, keyHash);
            positionSettingsMap[keyHash].automateRewards = true;
            positionSettingsMap[keyHash].rewardConfig = rewardConfig;
            overridesPrevious[keyHash] = true;
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
            overridesPrevious[keyHash] = true;
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

    /// @dev Copy `previousRegistry`'s entry into local storage ahead of a
    /// partial write. Full writes need none of this — they replace the whole
    /// struct — but `setMultiplePositionSettings` only touches the reward
    /// fields, and the tombstone it sets would otherwise strand the rest of
    /// the position's settings (pool, router, exit config) in the predecessor.
    function _materializePrevious(
        PositionKey memory key,
        bytes32 keyHash
    ) private {
        if (
            overridesPrevious[keyHash]
                || address(previousRegistry) == address(0)
        ) {
            return;
        }
        positionSettingsMap[keyHash] =
            previousRegistry.getPositionSettings(key);
    }

    /// @dev Validate the one constructor argument the type system cannot:
    /// every address satisfies `IPositionSettingsRegistry`, so a typo, an EOA,
    /// or another chain's address all compile. Any of them silently bricks
    /// every not-yet-migrated read — and with it every validator — while the
    /// deploy still looks like it succeeded. One plain typed call settles it:
    /// Solidity's `extcodesize` guard rejects an address holding no code, and
    /// decoding the reply rejects anything that does not answer in this
    /// contract's own shape. No byte counting, so nothing here rots when
    /// `PositionSettings` gains a field. Chains with no predecessor pass
    /// address(0) and skip this entirely.
    ///
    /// The zero key cannot have been written — every write path resolves a
    /// real sickle — so a conforming registry answers with an empty struct.
    /// A predecessor on a wholly different layout whose zero-key reply happens
    /// to be all zeros still decodes; guarding that is the deploy path's job,
    /// which pins `previousRegistry` to the chain's recorded registry.
    function _checkPreviousRegistry(
        IPositionSettingsRegistry registry
    ) private view {
        registry.getPositionSettings(
            PositionKey({
                sickle: Sickle(payable(address(0))),
                stakingContract: address(0),
                poolIndex: 0
            })
        );
    }

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
