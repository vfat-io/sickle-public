// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CompoundTarget } from "contracts/structs/MoveSettingsStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import { NftKey } from "contracts/structs/NftSettingsStructs.sol";
import { PositionKey } from "contracts/structs/PositionSettingsStructs.sol";
import { ISettingsModule } from "contracts/interfaces/ISettingsModule.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { Sickle } from "contracts/Sickle.sol";

/**
 * @notice A position's multi-compound opt-in.
 * @param enabled Whether the position is opted in; a zeroed mapping slot
 * reads back as `enabled = false`, which is the "not opted in" signal.
 * @param target The farm this position's rewards may be consolidated into.
 * A position whose `target` equals its own farm is a valid consolidation
 * destination; one pinned to a different farm is a source for that farm
 * only and can never be used as a deposit target.
 * @param targetPoolId The PoolId of the NFT target when `target` is a
 * V4-style position-manager farm. Legacy ERC20 and V3-style NFT targets use
 * `bytes32(0)`.
 */
struct MultiCompoundConfig {
    bool enabled;
    Farm target;
    /// @notice Destination pool for V4-style managers, derived on-chain from
    /// the destination position. Always zero for V3-style managers, whose
    /// connectors report no PoolId.
    bytes32 targetPoolId;
    /// @notice Destination pool for V3-style managers, where `targetPoolId`
    /// cannot distinguish two pools under the same position manager. Declared
    /// by the owner on BOTH the source and the destination config; the
    /// strategy requires them to agree, which is what stops rewards
    /// configured for one pool being consolidated into another. Zero for
    /// V4-style destinations, which are identified by `targetPoolId` instead.
    address targetPool;
    /// @notice The farm an NFT source's rewards must be claimed from. The
    /// NFT config key is (sickle, nftManager, tokenId) and carries no farm, so
    /// without this a keeper could pair an enabled key with an unrelated
    /// connector-backed source. Unused for ERC-20 configs, whose PositionKey
    /// already encodes the staking contract and pool index.
    Farm source;
}

/// @title MultiCompoundSettingsRegistry
/// @notice Typed, per-position settings for multi-compound automation, kept
/// out of the core `NftSettings` / `PositionSettings` structs so the feature
/// ships without redeploying the core settings registries. Registered as an
/// `ISettingsModule` with `NftSettingsRegistry`, which drives `onRebalance`
/// so an NFT position's opt-in survives a `tokenId` change.
/// @dev Adding the next automation feature is the same shape: a new typed
/// registry implementing `ISettingsModule`, registered with the core
/// registry — no core struct change, no `bytes` blob.
/// Replacements inherit unwritten keys from `previousRegistry`; revocations
/// mask inherited opt-ins. Recognized Sickles can migrate settings and group
/// targets atomically while owner writes retain their normal authority.
contract MultiCompoundSettingsRegistry is ISettingsModule {
    /// ERRORS ///
    error NotSickleOwner();
    error OnlyNftSettingsRegistry();
    error ConfigNotEnabled();

    /// @notice Revoking an opt-in that is not there. Most often an obsolete
    /// tokenId whose config a rebalance already migrated to its replacement.
    error ConfigNotSet();

    /// @notice An NFT opt-in left its source farm undeclared. The key carries
    /// no farm, so the config would be unusable as a claim source.
    error SourceFarmNotDeclared();

    /// EVENTS ///

    event NftConfigSet(NftKey key, MultiCompoundConfig config);
    event NftConfigUnset(NftKey key);
    event Erc20ConfigSet(PositionKey key, MultiCompoundConfig config);
    event Erc20ConfigUnset(PositionKey key);

    /// STORAGE ///

    /// @notice Resolves a Sickle's owner, who is authorised to opt in.
    SickleFactory public immutable factory;
    /// @notice The core registry permitted to drive `onRebalance`.
    address public immutable nftSettingsRegistry;

    // NFT positions: keyed by NftKey. `tokenId` is not rebalance-stable, so
    // these entries are migrated by `onRebalance`.
    mapping(bytes32 => MultiCompoundConfig) nftConfigMap;
    // ERC20 farm positions: keyed by PositionKey. A farm is rebalance-stable,
    // so these entries never need migration.
    mapping(bytes32 => MultiCompoundConfig) erc20ConfigMap;

    uint256 public constant MIGRATION_SETTINGS_VERSION = 1;
    MultiCompoundSettingsRegistry public immutable previousRegistry;
    mapping(bytes32 => bool) private nftWritten;
    mapping(bytes32 => bool) private erc20Written;
    mapping(bytes32 => uint256) private nftWriteEpoch;
    mapping(bytes32 => uint256) private erc20WriteEpoch;
    mapping(address => uint256) public targetEpoch;

    struct TargetRedirect {
        uint256 epoch;
        CompoundTarget target;
    }
    mapping(bytes32 => TargetRedirect[]) private targetRedirects;
    mapping(bytes32 => uint256) private redirectDepth;
    uint256 public constant MAX_TARGET_REDIRECT_HOPS = 16;

    event CompoundTargetMigrated(
        Sickle indexed sickle,
        uint256 epoch,
        CompoundTarget oldTarget,
        CompoundTarget newTarget
    );

    error InvalidPredecessor();
    error OnlySickle();
    error InvalidMigrationKey();
    error TargetMismatch();
    error SourceMismatch();
    error RedirectCycle();
    error RedirectLimit();

    constructor(
        SickleFactory factory_,
        address nftSettingsRegistry_,
        MultiCompoundSettingsRegistry previous_
    ) {
        factory = factory_;
        nftSettingsRegistry = nftSettingsRegistry_;
        if (address(previous_) != address(0)) {
            if (
                address(previous_).code.length == 0
                    || previous_.factory() != factory_
            ) revert InvalidPredecessor();
            NftKey memory probe;
            try previous_.getNftConfig(probe) returns (
                MultiCompoundConfig memory
            ) { }
            catch {
                revert InvalidPredecessor();
            }
        }
        previousRegistry = previous_;
    }

    /// @notice Opt an NFT position into multi-compound automation.
    /// @custom:access Restricted to the Sickle owner.
    function setNftConfig(
        NftKey calldata key,
        MultiCompoundConfig calldata config
    ) external {
        _onlySickleOwner(key.sickle);
        if (!config.enabled) revert ConfigNotEnabled();
        // The NFT key carries no farm; bind claims to this declared source
        // at write time rather than leaving an unusable opt-in for execution.
        if (config.source.stakingContract == address(0)) {
            revert SourceFarmNotDeclared();
        }
        _setNftConfig(key, config);
    }

    /// @notice Clear an NFT position's multi-compound opt-in.
    /// @custom:access Restricted to the Sickle owner.
    function unsetNftConfig(
        NftKey calldata key
    ) external {
        _onlySickleOwner(key.sickle);
        // A rebalance can replace tokenId before this revocation is mined.
        // Fail on the obsolete key so the caller retries against the live
        // replacement instead of reporting a successful ineffective revoke.
        if (!_getNftConfig(key).enabled) revert ConfigNotSet();
        _clearNftConfig(key);
    }

    /// @notice Opt an ERC20 farm position into multi-compound automation.
    /// @custom:access Restricted to the Sickle owner.
    function setErc20Config(
        PositionKey calldata key,
        MultiCompoundConfig calldata config
    ) external {
        _onlySickleOwner(key.sickle);
        if (!config.enabled) revert ConfigNotEnabled();
        _setErc20Config(key, config);
    }

    /// @notice Clear an ERC20 farm position's multi-compound opt-in.
    /// @custom:access Restricted to the Sickle owner.
    function unsetErc20Config(
        PositionKey calldata key
    ) external {
        _onlySickleOwner(key.sickle);
        // Do not report success for an absent or already-revoked policy.
        if (!_getErc20Config(key).enabled) revert ConfigNotSet();
        _clearErc20Config(key);
    }

    function getNftConfig(
        NftKey calldata key
    ) external view returns (MultiCompoundConfig memory) {
        return _getNftConfig(key);
    }

    function getErc20Config(
        PositionKey calldata key
    ) external view returns (MultiCompoundConfig memory) {
        return _getErc20Config(key);
    }

    /// @notice Migrate an NFT position's opt-in when a rebalance changes its
    /// `tokenId`. A no-op for a position with no opt-in.
    /// @custom:access Restricted to `NftSettingsRegistry`, which calls this
    /// from `transferNftSettings`.
    function onRebalance(
        NftKey calldata oldKey,
        NftKey calldata newKey
    ) external {
        if (msg.sender != nftSettingsRegistry) {
            revert OnlyNftSettingsRegistry();
        }
        MultiCompoundConfig memory config = _getNftConfig(oldKey);
        if (!config.enabled) return;
        _clearNftConfig(oldKey);
        _setNftConfig(newKey, config);
    }

    function migrateNftConfig(
        NftKey calldata oldKey,
        NftKey calldata newKey,
        Farm calldata oldSource,
        Farm calldata newSource,
        CompoundTarget calldata expectedTarget,
        CompoundTarget calldata target
    ) external {
        _checkKeys(oldKey.sickle, newKey);
        if (address(oldKey.nftManager) == address(0) || oldKey.tokenId == 0) {
            revert InvalidMigrationKey();
        }
        if (
            oldKey.nftManager == newKey.nftManager
                && oldKey.tokenId == newKey.tokenId
        ) revert InvalidMigrationKey();
        MultiCompoundConfig memory config = _getNftConfig(oldKey);
        if (config.enabled && !_sameFarm(config.source, oldSource)) {
            revert SourceMismatch();
        }
        _clearNftConfig(oldKey);
        _writeMigrated(newKey, config, newSource, expectedTarget, target);
    }

    function migrateErc20Config(
        PositionKey calldata oldKey,
        NftKey calldata newKey,
        Farm calldata newSource,
        CompoundTarget calldata expectedTarget,
        CompoundTarget calldata target
    ) external {
        _checkKeys(oldKey.sickle, newKey);
        if (oldKey.stakingContract == address(0)) revert InvalidMigrationKey();
        MultiCompoundConfig memory config = _getErc20Config(oldKey);
        _clearErc20Config(oldKey);
        _writeMigrated(newKey, config, newSource, expectedTarget, target);
    }

    function remapNftTarget(
        NftKey calldata key,
        Farm calldata source,
        CompoundTarget calldata expectedTarget,
        CompoundTarget calldata target
    ) external {
        _onlySickle(key.sickle);
        MultiCompoundConfig memory config = _getNftConfig(key);
        if (!config.enabled) revert ConfigNotSet();
        if (!_sameFarm(config.source, source)) revert SourceMismatch();
        _setNftConfig(key, _retarget(config, expectedTarget, target));
    }

    function remapErc20Target(
        PositionKey calldata key,
        CompoundTarget calldata expectedTarget,
        CompoundTarget calldata target
    ) external {
        _onlySickle(key.sickle);
        MultiCompoundConfig memory config = _getErc20Config(key);
        if (!config.enabled) revert ConfigNotSet();
        _setErc20Config(key, _retarget(config, expectedTarget, target));
    }

    /// @notice Remap all current and inherited group members atomically,
    /// including members absent from a quote or written before it is mined.
    /// Later owner writes stamp the current epoch and may intentionally select
    /// the old farm again. Histories retain earlier groups' original redirects.
    function migrateTarget(
        Sickle sickle,
        CompoundTarget calldata oldTarget,
        CompoundTarget calldata newTarget
    ) external {
        _onlySickle(sickle);
        if (
            oldTarget.farm.stakingContract == address(0)
                || newTarget.farm.stakingContract == address(0)
        ) revert TargetMismatch();
        CompoundTarget memory canonical =
            _previewTargetMigration(sickle, oldTarget, newTarget);
        bytes32 oldHash = _targetHash(sickle, oldTarget);
        bytes32 newHash = _targetHash(sickle, canonical);
        uint256 depth = redirectDepth[oldHash] + 1;
        if (depth > MAX_TARGET_REDIRECT_HOPS) revert RedirectLimit();
        if (depth > redirectDepth[newHash]) redirectDepth[newHash] = depth;
        uint256 epoch = ++targetEpoch[address(sickle)];
        targetRedirects[oldHash].push(TargetRedirect(epoch, canonical));
        emit CompoundTargetMigrated(sickle, epoch, oldTarget, canonical);
    }

    function previewTargetMigration(
        Sickle sickle,
        CompoundTarget calldata oldTarget,
        CompoundTarget calldata newTarget
    ) external view {
        _previewTargetMigration(sickle, oldTarget, newTarget);
    }

    function _previewTargetMigration(
        Sickle sickle,
        CompoundTarget memory oldTarget,
        CompoundTarget memory newTarget
    ) private view returns (CompoundTarget memory canonical) {
        canonical = _resolveTarget(sickle, newTarget, 0);
        if (_targetHash(sickle, oldTarget) == _targetHash(sickle, canonical)) {
            revert RedirectCycle();
        }
        if (
            redirectDepth[_targetHash(sickle, oldTarget)] + 1
                > MAX_TARGET_REDIRECT_HOPS
        ) revert RedirectLimit();
    }

    function resolveTarget(
        Sickle sickle,
        CompoundTarget calldata target,
        uint256 writeEpoch
    ) external view returns (CompoundTarget memory) {
        return _resolveTarget(sickle, target, writeEpoch);
    }

    function _resolveTarget(
        Sickle sickle,
        CompoundTarget memory target,
        uint256 writeEpoch
    ) private view returns (CompoundTarget memory) {
        for (uint256 hop; hop <= MAX_TARGET_REDIRECT_HOPS; ++hop) {
            TargetRedirect[] storage history =
                targetRedirects[_targetHash(sickle, target)];
            uint256 low;
            uint256 high = history.length;
            // First redirect newer than this entry's write/last hop. Choosing
            // the latest would silently move an older, already-migrated group.
            while (low < high) {
                uint256 middle = (low + high) / 2;
                if (history[middle].epoch <= writeEpoch) low = middle + 1;
                else high = middle;
            }
            if (low == history.length) return target;
            if (hop == MAX_TARGET_REDIRECT_HOPS) revert RedirectLimit();
            target = history[low].target;
            writeEpoch = history[low].epoch;
        }
        revert RedirectLimit();
    }

    function _targetHash(
        Sickle sickle,
        CompoundTarget memory target
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(sickle, target));
    }

    function _resolveConfig(
        Sickle sickle,
        MultiCompoundConfig memory config,
        uint256 epoch
    ) private view returns (MultiCompoundConfig memory) {
        if (!config.enabled) return config;
        CompoundTarget memory target = _resolveTarget(
            sickle,
            CompoundTarget(
                config.target, config.targetPoolId, config.targetPool
            ),
            epoch
        );
        config.target = target.farm;
        config.targetPoolId = target.poolId;
        config.targetPool = target.pool;
        return config;
    }

    function _writeMigrated(
        NftKey calldata key,
        MultiCompoundConfig memory config,
        Farm calldata newSource,
        CompoundTarget calldata expectedTarget,
        CompoundTarget calldata target
    ) private {
        if (!config.enabled) {
            _clearNftConfig(key);
            return;
        }
        if (newSource.stakingContract == address(0)) {
            revert SourceFarmNotDeclared();
        }
        config = _retarget(config, expectedTarget, target);
        config.source = newSource;
        _setNftConfig(key, config);
    }

    function _retarget(
        MultiCompoundConfig memory config,
        CompoundTarget calldata expectedTarget,
        CompoundTarget calldata target
    ) private pure returns (MultiCompoundConfig memory) {
        if (
            !_sameFarm(config.target, expectedTarget.farm)
                || config.targetPoolId != expectedTarget.poolId
                || config.targetPool != expectedTarget.pool
        ) revert TargetMismatch();
        if (
            target.farm.stakingContract == address(0)
                && keccak256(abi.encode(target))
                    != keccak256(abi.encode(expectedTarget))
        ) revert TargetMismatch();
        config.target = target.farm;
        config.targetPoolId = target.poolId;
        config.targetPool = target.pool;
        return config;
    }

    function _sameFarm(
        Farm memory a,
        Farm memory b
    ) private pure returns (bool) {
        return
            a.stakingContract == b.stakingContract && a.poolIndex == b.poolIndex;
    }

    function _onlySickle(
        Sickle sickle
    ) private view {
        if (
            msg.sender != address(sickle)
                || factory.admins(msg.sender) == address(0)
        ) revert OnlySickle();
    }

    function _checkKeys(
        Sickle sickle,
        NftKey calldata key
    ) private view {
        _onlySickle(sickle);
        if (
            key.sickle != sickle || address(key.nftManager) == address(0)
                || key.tokenId == 0
        ) revert InvalidMigrationKey();
    }

    function _getNftConfig(
        NftKey memory key
    ) internal view returns (MultiCompoundConfig memory) {
        bytes32 hash = keccak256(abi.encode(key));
        if (!nftWritten[hash] && address(previousRegistry) != address(0)) {
            return
                _resolveConfig(
                    key.sickle, previousRegistry.getNftConfig(key), 0
                );
        }
        return
            _resolveConfig(key.sickle, nftConfigMap[hash], nftWriteEpoch[hash]);
    }

    function _getErc20Config(
        PositionKey memory key
    ) internal view returns (MultiCompoundConfig memory) {
        bytes32 hash = keccak256(abi.encode(key));
        if (!erc20Written[hash] && address(previousRegistry) != address(0)) {
            return _resolveConfig(
                key.sickle, previousRegistry.getErc20Config(key), 0
            );
        }
        return _resolveConfig(
            key.sickle, erc20ConfigMap[hash], erc20WriteEpoch[hash]
        );
    }

    function _setNftConfig(
        NftKey memory key,
        MultiCompoundConfig memory config
    ) internal {
        nftWritten[keccak256(abi.encode(key))] = true;
        nftWriteEpoch[keccak256(abi.encode(key))] =
            targetEpoch[address(key.sickle)];
        nftConfigMap[keccak256(abi.encode(key))] = config;
        emit NftConfigSet(key, config);
    }

    function _setErc20Config(
        PositionKey memory key,
        MultiCompoundConfig memory config
    ) internal {
        erc20Written[keccak256(abi.encode(key))] = true;
        erc20WriteEpoch[keccak256(abi.encode(key))] =
            targetEpoch[address(key.sickle)];
        erc20ConfigMap[keccak256(abi.encode(key))] = config;
        emit Erc20ConfigSet(key, config);
    }

    function _clearNftConfig(
        NftKey memory key
    ) internal {
        nftWritten[keccak256(abi.encode(key))] = true;
        delete nftConfigMap[keccak256(abi.encode(key))];
        emit NftConfigUnset(key);
    }

    function _clearErc20Config(
        PositionKey memory key
    ) internal {
        erc20Written[keccak256(abi.encode(key))] = true;
        delete erc20ConfigMap[keccak256(abi.encode(key))];
        emit Erc20ConfigUnset(key);
    }

    function _onlySickleOwner(
        Sickle sickle
    ) internal view {
        if (factory.admins(address(sickle)) != msg.sender) {
            revert NotSickleOwner();
        }
    }
}
