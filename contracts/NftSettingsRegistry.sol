// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

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
import { ISettingsModule } from "contracts/interfaces/ISettingsModule.sol";

contract NftSettingsRegistry is TimelockAdmin, INftSettingsRegistry {
    uint256 constant MAX_SLIPPAGE_BP = 500;
    uint256 constant MAX_PRICE_IMPACT_BP = 5000;
    uint256 constant MAX_DUST_BP = 5000;
    int24 constant MAX_TICK = 887_272;
    int24 constant MIN_TICK = -MAX_TICK;

    SickleFactory public immutable factory;

    /// @notice Registry this one replaces, read through on a local miss so a
    /// redeploy does not strand existing per-position settings.
    /// @dev Zero on chains with no predecessor, which disables the fallback.
    /// Typed as `INftSettingsRegistry`, not a frozen copy of some older
    /// struct: the predecessor answers in whatever shape it was built with,
    /// and `getNftSettings` is itself public and self-falling-back, so a
    /// predecessor that needs to bridge an older layout does that internally,
    /// in bytecode that is already deployed. Point this at the chain's CURRENT
    /// registry and generations chain recursively; point it at an older one
    /// and you skip whatever that chain's current registry was bridging.
    /// This registry never writes to its predecessor: every write lands
    /// locally, so a position migrates itself the first time it is written.
    INftSettingsRegistry public immutable previousRegistry;

    ConnectorRegistry private _connectorRegistry;

    constructor(
        SickleFactory _factory,
        ConnectorRegistry connectorRegistry,
        address timelockAdmin,
        INftSettingsRegistry _previousRegistry
    ) TimelockAdmin(timelockAdmin) {
        if (address(_previousRegistry) != address(0)) {
            _checkPreviousRegistry(_previousRegistry);
        }
        factory = _factory;
        previousRegistry = _previousRegistry;
        _connectorRegistry = connectorRegistry;
        emit ConnectionRegistrySet(address(connectorRegistry));
    }

    mapping(bytes32 => NftSettings) settingsMap;

    /// @notice Keys this registry answers for itself, suppressing the
    /// `previousRegistry` fallback. Set by every local write, including an
    /// unset.
    /// @dev A tombstone is required because `_unsetNftSettings` clears
    /// `settingsMap`, and a cleared entry is otherwise indistinguishable from
    /// "never written here" — an unset position would fall through and read
    /// as set again. The same flag also covers the mirror case: an all-default
    /// `NftSettings` is a legal write (`checkConfigValues` permits it, and it
    /// is how a user turns every automation off), and stores as an empty
    /// struct, so emptiness cannot be the discriminator either. Marking on
    /// every write, not just on unset, settles both with one slot.
    mapping(bytes32 => bool) public overridesPrevious;

    /// @notice Pluggable per-position settings modules. On a rebalance,
    /// `transferNftSettings` calls `onRebalance` on each so a module keying
    /// state by `NftKey` migrates it without wiring its own rebalance hook.
    ISettingsModule[] public settingsModules;

    error SettingsModuleNotFound();

    event SettingsModuleRegistered(address module);
    event SettingsModuleDeregistered(address module);

    /*  Timelock functions */

    function setConnectorRegistry(
        ConnectorRegistry connectorRegistry
    ) external onlyTimelockAdmin {
        _connectorRegistry = connectorRegistry;
        emit ConnectionRegistrySet(address(connectorRegistry));
    }

    function settingsModulesLength() external view returns (uint256) {
        return settingsModules.length;
    }

    function registerSettingsModule(
        ISettingsModule module
    ) external onlyTimelockAdmin {
        settingsModules.push(module);
        emit SettingsModuleRegistered(address(module));
    }

    function deregisterSettingsModule(
        ISettingsModule module
    ) external onlyTimelockAdmin {
        uint256 length = settingsModules.length;
        for (uint256 i; i < length;) {
            if (settingsModules[i] == module) {
                settingsModules[i] = settingsModules[length - 1];
                settingsModules.pop();
                emit SettingsModuleDeregistered(address(module));
                return;
            }
            unchecked {
                ++i;
            }
        }
        revert SettingsModuleNotFound();
    }

    /* Public functions */

    /// @notice Settings for `key`, falling back to `previousRegistry` for
    /// positions that have never been written here.
    /// @dev Public and inline on purpose: the predecessor's own
    /// `getNftSettings` falls back the same way, so a lookup walks the whole
    /// ancestry rather than a single hop — including any older layout that
    /// predecessor bridges internally. Same shape end to end, so no field is
    /// dropped on the way back: an earlier design converted into a
    /// pre-`autoDeposit` struct and forced that flag off on every read.
    function getNftSettings(
        NftKey memory key
    ) public view returns (NftSettings memory) {
        bytes32 keyHash = keccak256(abi.encode(key));
        if (
            overridesPrevious[keyHash]
                || address(previousRegistry) == address(0)
        ) {
            return settingsMap[keyHash];
        }
        return previousRegistry.getNftSettings(key);
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

    // @notice Validate that depositFor (automated dust deposit) is enabled
    function validateDepositFor(
        NftKey memory key
    ) public view {
        NftSettings memory settings = getNftSettings(key);
        if (!settings.autoDeposit) {
            revert AutoDepositNotSet();
        }
    }

    // @notice Validate that a rebalanceFor meets the user requirements
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

    // @notice Transfer NFT settings from the old NFT to the new one during a
    // rebalance.
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

        // Migrate any module-held per-position settings to the new tokenId.
        uint256 moduleCount = settingsModules.length;
        for (uint256 i; i < moduleCount;) {
            settingsModules[i].onRebalance(oldKey, newKey);
            unchecked {
                ++i;
            }
        }
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
        bytes32 keyHash = keccak256(abi.encode(key));
        settingsMap[keyHash] = settings;
        overridesPrevious[keyHash] = true;
        emit NftSettingsSet(key, settings);
    }

    function _unsetNftSettings(
        NftKey memory key
    ) internal {
        bytes32 keyHash = keccak256(abi.encode(key));
        delete settingsMap[keyHash];
        // Tombstone, so the cleared entry does not read through to
        // `previousRegistry` and come back set.
        overridesPrevious[keyHash] = true;
        emit NftSettingsUnset(key);
    }

    /// @dev Validate the one constructor argument the type system cannot:
    /// every address satisfies `INftSettingsRegistry`, so a typo, an EOA, or
    /// another chain's address all compile. Any of them silently bricks every
    /// not-yet-migrated read — and with it every validator — while the deploy
    /// still looks like it succeeded. One plain typed call settles it:
    /// Solidity's `extcodesize` guard rejects an address holding no code, and
    /// decoding the reply rejects anything that does not answer in this
    /// contract's own shape. No byte counting, so nothing here rots when
    /// `NftSettings` gains a field — the check this replaces pinned one exact
    /// returndata length and started rejecting current-shape predecessors the
    /// moment `autoDeposit` was appended. Chains with no predecessor pass
    /// address(0) and skip this entirely.
    ///
    /// The zero key cannot have been written — `checkConfigValues` rejects a
    /// zero `nftManager` — so a conforming registry answers with an empty
    /// struct. A predecessor on a wholly different layout whose zero-key reply
    /// happens to be all zeros still decodes; guarding that is the deploy
    /// path's job, which pins `previousRegistry` to the chain's recorded
    /// registry.
    function _checkPreviousRegistry(
        INftSettingsRegistry registry
    ) private view {
        registry.getNftSettings(
            NftKey({
                sickle: Sickle(payable(address(0))),
                nftManager: INonfungiblePositionManager(address(0)),
                tokenId: 0
            })
        );
    }

    // @dev Check configuration parameters for errors
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
