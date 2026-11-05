// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    AeroMigrationStrategy
} from "contracts/strategies/AeroMigrationStrategy.sol";
import {
    CrossFarmMoveStrategy
} from "contracts/strategies/CrossFarmMoveStrategy.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {
    IAeroFactoryRegistry
} from "contracts/interfaces/external/aero/IAeroFactoryRegistry.sol";
import {
    AeroMigrationSettingsLib
} from "contracts/libraries/AeroMigrationSettingsLib.sol";
import { Sickle } from "contracts/Sickle.sol";
import { NftKey } from "contracts/structs/NftSettingsStructs.sol";
import {
    CompoundMember,
    AeroMigrationSource,
    AeroMigrationDestination
} from "contracts/structs/AeroMigrationSettingsStructs.sol";

/// @notice Additive owner entrypoint preserving core and auxiliary settings in
/// the same atomic transaction as all selected position migrations.
contract AeroMigrationStrategyWithSettings is AeroMigrationStrategy {
    uint256 public constant SETTINGS_MIGRATION_VERSION = 1;
    AeroMigrationSettingsLib public immutable settingsLib;
    error SettingsMigrationRequired();

    constructor(
        CrossFarmMoveStrategy move_,
        INonfungiblePositionManager nft_,
        IAeroFactoryRegistry registry_,
        AeroMigrationSettingsLib settings_
    ) AeroMigrationStrategy(move_, nft_, registry_) {
        if (
            address(settings_).code.length == 0
                || settings_.moveStrategy() != move_
        ) revert InvalidConfiguration();
        settingsLib = settings_;
    }

    /// @dev Retained selector, fail closed on the settings-aware generation.
    function migrate(
        Migration[] calldata,
        uint256
    ) external pure override returns (uint256[] memory) {
        revert SettingsMigrationRequired();
    }

    function migrateWithSettings(
        Migration[] calldata migrations,
        uint256[] calldata compoundTargetLegs,
        CompoundMember[] calldata compoundMembers,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory tokenIds) {
        if (address(this) != self) revert DirectCallRequired();
        Sickle sickle = moveStrategy.getSickle(msg.sender);
        AeroMigrationSource[] memory sources = settingsLib.prepare(
            sickle, migrations, compoundTargetLegs, compoundMembers
        );
        tokenIds = _migrate(migrations, deadline);
        // Coverage compiles with viaIR. Building the destinations and the
        // settings multicall in this frame is one stack slot over the EVM
        // limit, so each step has its own frame.
        _writeMigratedSettings(
            sickle,
            sources,
            _migratedDestinations(sickle, tokenIds, migrations),
            compoundTargetLegs,
            compoundMembers
        );
    }

    function _migratedDestinations(
        Sickle sickle,
        uint256[] memory tokenIds,
        Migration[] calldata migrations
    ) private view returns (AeroMigrationDestination[] memory destinations) {
        uint256 length = migrations.length;
        destinations = new AeroMigrationDestination[](length);
        for (uint256 i; i < length; ++i) {
            destinations[i] = AeroMigrationDestination(
                NftKey(sickle, aeroNftManager, tokenIds[i]),
                migrations[i].move.deposit.farm,
                address(migrations[i].settings.pool)
            );
        }
    }

    function _writeMigratedSettings(
        Sickle sickle,
        AeroMigrationSource[] memory sources,
        AeroMigrationDestination[] memory destinations,
        uint256[] calldata compoundTargetLegs,
        CompoundMember[] calldata compoundMembers
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(settingsLib);
        data[0] = abi.encodeCall(
            AeroMigrationSettingsLib.applySettings,
            (sources, destinations, compoundTargetLegs, compoundMembers)
        );
        sickle.multicall(targets, data);
    }
}
