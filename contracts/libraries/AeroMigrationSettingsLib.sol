// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Sickle } from "contracts/Sickle.sol";
import {
    CrossFarmMoveStrategy
} from "contracts/strategies/CrossFarmMoveStrategy.sol";
import {
    AeroMigrationStrategy
} from "contracts/strategies/AeroMigrationStrategy.sol";
import {
    ExitDelaySettingsRegistry
} from "contracts/ExitDelaySettingsRegistry.sol";
import {
    MultiCompoundSettingsRegistry,
    MultiCompoundConfig
} from "contracts/MultiCompoundSettingsRegistry.sol";

import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { IGauge } from "contracts/interfaces/external/aerodrome/IGauge.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import { NftPoolKey } from "contracts/structs/NftLiquidityStructs.sol";
import { NftKey, NftSettings } from "contracts/structs/NftSettingsStructs.sol";
import {
    PositionKey,
    PositionSettings
} from "contracts/structs/PositionSettingsStructs.sol";
import {
    CompoundMember,
    CompoundTarget,
    AeroMigrationSource,
    AeroMigrationDestination
} from "contracts/structs/AeroMigrationSettingsStructs.sol";

/// @notice Fixed helper called normally for preflight and delegated only by
/// the owner's Sickle for typed module writes. All dependencies are immutable.
contract AeroMigrationSettingsLib {
    uint256 public constant NO_COMPOUND_TARGET = type(uint256).max;
    uint256 public constant MAX_COMPOUND_MEMBERS = 20;
    CrossFarmMoveStrategy public immutable moveStrategy;
    ExitDelaySettingsRegistry public immutable exitDelaySettingsRegistry;
    MultiCompoundSettingsRegistry public immutable
        multiCompoundSettingsRegistry;

    error InvalidConfiguration();
    error InvalidSettingsPlan();
    error PartialSource();
    error InvalidSourceToken();
    error UnsupportedUnstakedSource();
    error SourceNotControlled();
    error SourceNotRemoved();
    error InvalidCompoundTarget();
    error DestinationAlreadyRedirected();
    error DuplicateMember();
    error OnlySickle();

    constructor(
        CrossFarmMoveStrategy move_,
        ExitDelaySettingsRegistry exitDelay_,
        MultiCompoundSettingsRegistry multiCompound_
    ) {
        if (
            address(move_).code.length == 0
                || address(exitDelay_).code.length == 0
                || address(multiCompound_).code.length == 0
        ) revert InvalidConfiguration();
        if (
            exitDelay_.MIGRATION_SETTINGS_VERSION() != 1
                || multiCompound_.MIGRATION_SETTINGS_VERSION() != 1
                || exitDelay_.factory() != move_.factory()
                || multiCompound_.factory() != move_.factory()
                || exitDelay_.nftSettingsRegistry()
                    != address(move_.nftSettingsRegistry())
                || multiCompound_.nftSettingsRegistry()
                    != address(move_.nftSettingsRegistry())
        ) revert InvalidConfiguration();
        moveStrategy = move_;
        exitDelaySettingsRegistry = exitDelay_;
        multiCompoundSettingsRegistry = multiCompound_;
    }

    function prepare(
        Sickle sickle,
        AeroMigrationStrategy.Migration[] calldata migrations,
        uint256[] calldata targets,
        CompoundMember[] calldata members
    ) external view returns (AeroMigrationSource[] memory sources) {
        uint256 length = migrations.length;
        if (
            length == 0 || targets.length != length
                || members.length > MAX_COMPOUND_MEMBERS
                || moveStrategy.factory().admins(address(sickle)) == address(0)
        ) revert InvalidSettingsPlan();
        sources = new AeroMigrationSource[](length);
        for (uint256 i; i < length; ++i) {
            sources[i] = _source(sickle, migrations[i]);
        }
        for (uint256 i; i < length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (
                    _sameTarget(_oldTarget(sources[i]), _oldTarget(sources[j]))
                        && (!_sameFarm(
                                migrations[i].move.deposit.farm,
                                migrations[j].move.deposit.farm
                            )
                            || address(migrations[i].settings.pool)
                                != address(migrations[j].settings.pool))
                ) revert InvalidCompoundTarget();
            }
        }
        for (uint256 i; i < length; ++i) {
            CompoundTarget memory newTarget = CompoundTarget(
                migrations[i].move.deposit.farm,
                bytes32(0),
                address(migrations[i].settings.pool)
            );
            if (!_sameTarget(
                    newTarget,
                    multiCompoundSettingsRegistry.resolveTarget(
                        sickle, newTarget, 0
                    )
                )) revert DestinationAlreadyRedirected();
            multiCompoundSettingsRegistry.previewTargetMigration(
                sickle, _oldTarget(sources[i]), newTarget
            );
            // Aero destinations must be new identities. Overlapping selected
            // source identities would create an ambiguous redirect graph.
            for (uint256 j; j < length; ++j) {
                if (_sameTarget(newTarget, _oldTarget(sources[j]))) {
                    revert InvalidCompoundTarget();
                }
            }
        }
        _checkPlan(sickle, sources, targets, members);
    }

    function _source(
        Sickle sickle,
        AeroMigrationStrategy.Migration calldata leg
    ) private view returns (AeroMigrationSource memory source) {
        if (leg.move.farmSources.length + leg.move.nftSources.length != 1) {
            revert InvalidSettingsPlan();
        }
        if (leg.move.farmSources.length == 1) {
            source.farm = leg.move.farmSources[0].farm;
            source.settingsFarm = source.farm;
            source.lpToken =
            leg.move.farmSources[0].withdraw.zap.removeLiquidityParams.lpToken;
            IFarmConnector connector = IFarmConnector(
                moveStrategy.connectorRegistry()
                    .connectorOf(source.farm.stakingContract)
            );
            uint256 staked = connector.balanceOf(source.farm, address(sickle));
            uint256 held = IERC20(source.lpToken).balanceOf(address(sickle));
            // Bind the module key to the actual Aero/Velodrome gauge asset.
            // A nonstaking reward overlay can share one execution farm among
            // several LP pools, so the existing tuple cannot authenticate its
            // separate logical settings key or unique source identity.
            if (
                staked == 0 || !connector.isStaked(source.farm, address(sickle))
            ) revert UnsupportedUnstakedSource();
            (bool success, bytes memory result) = source.farm.stakingContract
                .staticcall(abi.encodeCall(IGauge.stakingToken, ()));
            if (
                source.farm.poolIndex != 0 || !success || result.length != 32
                    || abi.decode(result, (address)) != source.lpToken
            ) revert InvalidSourceToken();
            if (
                held != 0
                    || leg.move.farmSources[0].withdraw.zap
                            .removeLiquidityParams.lpAmountIn != staked
            ) revert PartialSource();
        } else {
            NftPosition calldata position = leg.move.nftSources[0].position;
            source.nft = position.nft;
            source.tokenId = position.tokenId;
            source.farm = position.farm;
            _checkNftCustody(sickle, position);
            MultiCompoundConfig memory config =
                multiCompoundSettingsRegistry.getNftConfig(
                    NftKey(sickle, source.nft, source.tokenId)
                );
            source.settingsFarm = config.enabled
                ? config.source
                : source.nft.ownerOf(source.tokenId) == address(sickle)
                    ? Farm(address(source.nft), 0)
                    : source.farm;
            moveStrategy.connectorRegistry()
                .connectorOf(source.settingsFarm.stakingContract);
            INftLiquidityConnector connector = INftLiquidityConnector(
                moveStrategy.connectorRegistry()
                    .connectorOf(address(source.nft))
            );
            (,, uint128 liquidity) =
                connector.positionLiquidity(address(source.nft), source.tokenId);
            uint128 requested =
                leg.move.nftSources[0].withdraw.zap.removeLiquidityParams
                .liquidity;
            if (
                liquidity == 0
                    || (requested != type(uint128).max
                        && requested != liquidity)
                    || leg.move.nftSources[0].withdraw.zap.removeLiquidityParams
                            .amount0Max != type(uint128).max
                    || leg.move.nftSources[0].withdraw.zap.removeLiquidityParams
                            .amount1Max != type(uint128).max
            ) revert PartialSource();
            NftPoolKey memory poolKey = connector.positionPoolKey(
                source.nft.factory(), address(source.nft), source.tokenId
            );
            if (
                poolKey.poolAddress == address(0)
                    || poolKey.poolId != bytes32(0)
            ) revert InvalidSettingsPlan();
            source.pool = poolKey.poolAddress;
        }
    }

    function _checkPlan(
        Sickle sickle,
        AeroMigrationSource[] memory sources,
        uint256[] calldata targets,
        CompoundMember[] calldata members
    ) private view {
        for (uint256 i; i < sources.length; ++i) {
            MultiCompoundConfig memory config = _config(sickle, sources[i]);
            uint256 target = targets[i];
            if (!config.enabled) {
                if (target != NO_COMPOUND_TARGET) {
                    revert InvalidCompoundTarget();
                }
            } else if (target == NO_COMPOUND_TARGET) {
                for (uint256 j; j < sources.length; ++j) {
                    if (_matches(config, _oldTarget(sources[j]))) {
                        revert InvalidCompoundTarget();
                    }
                }
            } else {
                _checkTarget(config, sources, target);
            }
        }
        for (uint256 i; i < members.length; ++i) {
            CompoundMember calldata member = members[i];
            if (
                member.farm.stakingContract == address(0)
                    || (address(member.nft) == address(0)
                        && member.tokenId != 0)
            ) revert InvalidSettingsPlan();
            bytes32 key = _memberKey(member);
            for (uint256 j; j < sources.length; ++j) {
                if (key == _sourceKey(sources[j])) revert DuplicateMember();
            }
            for (uint256 j; j < i; ++j) {
                if (key == _memberKey(members[j])) revert DuplicateMember();
            }
            MultiCompoundConfig memory config;
            if (address(member.nft) == address(0)) {
                // Authenticate the declared farm connector; this updates only
                // the owner's existing opt-in and never moves member assets.
                moveStrategy.connectorRegistry()
                    .connectorOf(member.farm.stakingContract);
                config = multiCompoundSettingsRegistry.getErc20Config(
                    _positionKey(sickle, member.farm)
                );
            } else {
                moveStrategy.connectorRegistry()
                    .connectorOf(address(member.nft));
                moveStrategy.connectorRegistry()
                    .connectorOf(member.farm.stakingContract);
                _checkNftCustody(
                    sickle, NftPosition(member.farm, member.nft, member.tokenId)
                );
                config = multiCompoundSettingsRegistry.getNftConfig(
                    NftKey(sickle, member.nft, member.tokenId)
                );
                if (!_sameFarm(config.source, member.farm)) {
                    revert InvalidSettingsPlan();
                }
            }
            _checkTarget(config, sources, member.targetLeg);
        }
    }

    function _checkTarget(
        MultiCompoundConfig memory config,
        AeroMigrationSource[] memory sources,
        uint256 target
    ) private pure {
        if (
            !config.enabled || target >= sources.length
                || !_matches(config, _oldTarget(sources[target]))
        ) revert InvalidCompoundTarget();
    }

    function _checkNftCustody(
        Sickle sickle,
        NftPosition memory position
    ) private view {
        if (position.tokenId == 0) revert SourceNotControlled();
        if (position.nft.ownerOf(position.tokenId) == address(sickle)) return;
        INftFarmConnector connector = INftFarmConnector(
            moveStrategy.connectorRegistry()
                .connectorOf(position.farm.stakingContract)
        );
        try connector.isStaked(address(sickle), position) returns (
            bool staked
        ) {
            if (!staked) revert SourceNotControlled();
        } catch {
            revert SourceNotControlled();
        }
    }

    /// @dev Delegate entry: msg.sender is the approved wrapper; address(this)
    /// is the recognized owner Sickle, which normally CALLs the registries.
    function applySettings(
        AeroMigrationSource[] calldata sources,
        AeroMigrationDestination[] calldata destinations,
        uint256[] calldata targets,
        CompoundMember[] calldata members
    ) external {
        Sickle sickle = Sickle(payable(address(this)));
        if (moveStrategy.factory().admins(address(this)) == address(0)) {
            revert OnlySickle();
        }
        if (
            sources.length == 0 || destinations.length != sources.length
                || targets.length != sources.length
                || members.length > MAX_COMPOUND_MEMBERS
        ) revert InvalidSettingsPlan();
        _checkPlan(sickle, sources, targets, members);
        for (uint256 i; i < sources.length; ++i) {
            _checkRemoved(sickle, sources[i]);
        }
        for (uint256 i; i < destinations.length; ++i) {
            if (destinations[i].key.sickle != sickle) {
                revert InvalidSettingsPlan();
            }
            _checkNftCustody(
                sickle,
                NftPosition(
                    destinations[i].farm,
                    destinations[i].key.nftManager,
                    destinations[i].key.tokenId
                )
            );
        }
        // Inbound members are rewritten before selected sources are cleared,
        // so every expected old group identity remains available for checks.
        for (uint256 i; i < members.length; ++i) {
            _remapMember(
                sickle,
                members[i],
                sources[members[i].targetLeg],
                destinations[members[i].targetLeg]
            );
        }
        _migrateSources(sickle, sources, destinations, targets);
        _recordTargets(sickle, sources, destinations);
    }

    function _recordTargets(
        Sickle sickle,
        AeroMigrationSource[] calldata sources,
        AeroMigrationDestination[] calldata destinations
    ) private {
        for (uint256 i; i < sources.length; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (_sameTarget(_oldTarget(sources[i]), _oldTarget(sources[j])))
                {
                    if (!_sameTarget(
                            _newTarget(destinations[i]),
                            _newTarget(destinations[j])
                        )) revert InvalidCompoundTarget();
                    seen = true;
                }
            }
            if (!seen) {
                multiCompoundSettingsRegistry.migrateTarget(
                    sickle, _oldTarget(sources[i]), _newTarget(destinations[i])
                );
            }
        }
    }

    function _migrateSources(
        Sickle sickle,
        AeroMigrationSource[] calldata sources,
        AeroMigrationDestination[] calldata destinations,
        uint256[] calldata targets
    ) private {
        for (uint256 i; i < sources.length; ++i) {
            CompoundTarget memory target;
            if (targets[i] == NO_COMPOUND_TARGET) {
                target = _configTarget(_config(sickle, sources[i]));
            } else {
                target = _newTarget(destinations[targets[i]]);
            }
            _migrateSource(sickle, sources[i], destinations[i], target);
        }
    }

    function _checkRemoved(
        Sickle sickle,
        AeroMigrationSource calldata source
    ) private view {
        if (address(source.nft) == address(0)) {
            IFarmConnector connector = IFarmConnector(
                moveStrategy.connectorRegistry()
                    .connectorOf(source.farm.stakingContract)
            );
            if (
                connector.balanceOf(source.farm, address(sickle)) != 0
                    || IERC20(source.lpToken).balanceOf(address(sickle)) != 0
            ) revert SourceNotRemoved();
        } else {
            try source.nft.ownerOf(source.tokenId) returns (address owner) {
                if (owner != address(0)) revert SourceNotRemoved();
            } catch { }
        }
    }

    function _migrateSource(
        Sickle sickle,
        AeroMigrationSource calldata source,
        AeroMigrationDestination calldata destination,
        CompoundTarget memory target
    ) private {
        CompoundTarget memory expected = _configTarget(_config(sickle, source));
        if (address(source.nft) == address(0)) {
            PositionKey memory key = _positionKey(sickle, source.farm);
            exitDelaySettingsRegistry.migrateErc20Delay(key, destination.key);
            multiCompoundSettingsRegistry.migrateErc20Config(
                key, destination.key, destination.farm, expected, target
            );
            PositionSettings memory disabled;
            moveStrategy.positionSettingsRegistry()
                .setPositionSettings(key, disabled);
        } else {
            NftKey memory key = NftKey(sickle, source.nft, source.tokenId);
            exitDelaySettingsRegistry.migrateNftDelay(key, destination.key);
            multiCompoundSettingsRegistry.migrateNftConfig(
                key,
                destination.key,
                source.settingsFarm,
                destination.farm,
                expected,
                target
            );
            NftSettings memory disabled;
            moveStrategy.nftSettingsRegistry().setNftSettings(key, disabled);
        }
    }

    function _remapMember(
        Sickle sickle,
        CompoundMember calldata member,
        AeroMigrationSource calldata sourceTarget,
        AeroMigrationDestination calldata target
    ) private {
        CompoundTarget memory expected = _oldTarget(sourceTarget);
        CompoundTarget memory replacement = _newTarget(target);
        if (address(member.nft) == address(0)) {
            multiCompoundSettingsRegistry.remapErc20Target(
                _positionKey(sickle, member.farm), expected, replacement
            );
        } else {
            multiCompoundSettingsRegistry.remapNftTarget(
                NftKey(sickle, member.nft, member.tokenId),
                member.farm,
                expected,
                replacement
            );
        }
    }

    function _config(
        Sickle sickle,
        AeroMigrationSource memory source
    ) private view returns (MultiCompoundConfig memory) {
        if (address(source.nft) == address(0)) {
            return multiCompoundSettingsRegistry.getErc20Config(
                _positionKey(sickle, source.farm)
            );
        }
        return multiCompoundSettingsRegistry.getNftConfig(
            NftKey(sickle, source.nft, source.tokenId)
        );
    }

    function _positionKey(
        Sickle sickle,
        Farm memory farm
    ) private pure returns (PositionKey memory) {
        return PositionKey(sickle, farm.stakingContract, farm.poolIndex);
    }

    function _oldTarget(
        AeroMigrationSource memory source
    ) private pure returns (CompoundTarget memory) {
        return CompoundTarget(source.settingsFarm, bytes32(0), source.pool);
    }

    function _newTarget(
        AeroMigrationDestination memory destination
    ) private pure returns (CompoundTarget memory) {
        return CompoundTarget(destination.farm, bytes32(0), destination.pool);
    }

    function _configTarget(
        MultiCompoundConfig memory config
    ) private pure returns (CompoundTarget memory) {
        return
            CompoundTarget(
                config.target, config.targetPoolId, config.targetPool
            );
    }

    function _sameFarm(
        Farm memory a,
        Farm memory b
    ) private pure returns (bool) {
        return
            a.stakingContract == b.stakingContract && a.poolIndex == b.poolIndex;
    }

    function _matches(
        MultiCompoundConfig memory config,
        CompoundTarget memory target
    ) private pure returns (bool) {
        return _sameFarm(config.target, target.farm)
            && config.targetPoolId == target.poolId
            && config.targetPool == target.pool;
    }

    function _sameTarget(
        CompoundTarget memory a,
        CompoundTarget memory b
    ) private pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    function _sourceKey(
        AeroMigrationSource memory source
    ) private pure returns (bytes32) {
        return address(source.nft) == address(0)
            ? keccak256(abi.encode(uint8(0), source.farm))
            : keccak256(abi.encode(uint8(1), source.nft, source.tokenId));
    }

    function _memberKey(
        CompoundMember calldata member
    ) private pure returns (bytes32) {
        return address(member.nft) == address(0)
            ? keccak256(abi.encode(uint8(0), member.farm))
            : keccak256(abi.encode(uint8(1), member.nft, member.tokenId));
    }
}
