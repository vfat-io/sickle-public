// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {
    INftSettingsRegistry
} from "contracts/interfaces/INftSettingsRegistry.sol";
import {
    IPositionSettingsRegistry
} from "contracts/interfaces/IPositionSettingsRegistry.sol";
import {
    ExitDelaySettingsRegistry
} from "contracts/ExitDelaySettingsRegistry.sol";
import {
    MultiCompoundSettingsRegistry
} from "contracts/MultiCompoundSettingsRegistry.sol";
import {
    MultiCompoundConfig
} from "contracts/MultiCompoundSettingsRegistry.sol";
import { CompoundTarget } from "contracts/structs/MoveSettingsStructs.sol";
import {
    MovePosition,
    MoveSourceSettings
} from "contracts/structs/MoveSettingsStructs.sol";
import {
    FarmSource,
    NftFarmSource
} from "contracts/structs/CrossFarmMoveStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import { NftKey, NftSettings } from "contracts/structs/NftSettingsStructs.sol";
import {
    PositionKey,
    PositionSettings
} from "contracts/structs/PositionSettingsStructs.sol";
import { NftPoolKey } from "contracts/structs/NftLiquidityStructs.sol";
import { MoveBatchLib } from "contracts/libraries/MoveBatchLib.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

interface IMoveSettingsContext {
    function moveSettingsLib() external view returns (address);
}

/// @notice Shared settings lifecycle for ordinary and batched cross-farm moves.
/// @dev Preflight is normally called. applySettings is a fixed Sickle delegate
/// target: address(this) holds assets and is the registry caller; msg.sender is
/// the Move strategy. All dependencies are immutable; no Sickle storage writes.
contract MoveSettingsLib {
    SickleFactory public immutable factory;
    ConnectorRegistry public immutable connectorRegistry;
    INftSettingsRegistry public immutable nftSettingsRegistry;
    IPositionSettingsRegistry public immutable positionSettingsRegistry;
    ExitDelaySettingsRegistry public immutable exitDelaySettingsRegistry;
    MultiCompoundSettingsRegistry public immutable
        multiCompoundSettingsRegistry;
    MoveBatchLib public immutable batchLib;
    address private immutable self = address(this);
    mapping(address => bool) private entered;

    error InvalidConfiguration();
    error InvalidSource();
    error InvalidDestination();
    error UnsupportedFarmAsset();
    error SourceNotRemoved();
    error ConflictingSettings();
    error DuplicateSource();
    error OnlySickle();
    error OnlyMove();
    error DirectCallRequired();
    error ReentrantMove();
    error SettingsChanged();

    // This guard is normally called by Move. Keeping its storage here leaves
    // the strategy stateless and prevents writes to Sickle's storage layout.
    function enter() external {
        if (address(this) != self) revert DirectCallRequired();
        if (entered[msg.sender]) revert ReentrantMove();
        entered[msg.sender] = true;
    }

    function leave() external {
        if (address(this) != self) revert DirectCallRequired();
        entered[msg.sender] = false;
    }

    /// @dev Sickle.multicall authenticates the whitelisted caller. Require
    /// that caller to declare this helper too, so unrelated caller/selector
    /// registrations cannot reach the delegated settings writers.
    function _requireMove() private view {
        try IMoveSettingsContext(msg.sender).moveSettingsLib() returns (
            address helper
        ) {
            if (helper == self) return;
        } catch { }
        revert OnlyMove();
    }

    function hasFarmPosition(
        Sickle sickle,
        Farm calldata farm
    ) external view returns (bool existing) {
        address connector = connectorRegistry.connectorOf(farm.stakingContract);
        return IFarmConnector(connector).balanceOf(farm, address(sickle)) != 0;
    }

    constructor(
        SickleFactory factory_,
        ConnectorRegistry connectors_,
        INftSettingsRegistry nftSettings_,
        IPositionSettingsRegistry positionSettings_,
        ExitDelaySettingsRegistry delay_,
        MultiCompoundSettingsRegistry compound_
    ) {
        if (
            address(factory_).code.length == 0
                || address(connectors_).code.length == 0
                || address(nftSettings_).code.length == 0
                || address(positionSettings_).code.length == 0
                || address(delay_).code.length == 0
                || address(compound_).code.length == 0
                || delay_.factory() != factory_
                || compound_.factory() != factory_
                || delay_.nftSettingsRegistry() != address(nftSettings_)
                || compound_.nftSettingsRegistry() != address(nftSettings_)
        ) revert InvalidConfiguration();
        batchLib = new MoveBatchLib();
        factory = factory_;
        connectorRegistry = connectors_;
        nftSettingsRegistry = nftSettings_;
        positionSettingsRegistry = positionSettings_;
        exitDelaySettingsRegistry = delay_;
        multiCompoundSettingsRegistry = compound_;
    }

    function prepareSources(
        Sickle sickle,
        FarmSource[] calldata farms,
        NftFarmSource[] calldata nfts
    ) external view returns (MoveSourceSettings[] memory sources) {
        if (
            factory.admins(address(sickle)) == address(0)
                || farms.length + nfts.length == 0
        ) revert InvalidSource();
        sources = new MoveSourceSettings[](farms.length + nfts.length);
        for (uint256 i; i < farms.length; ++i) {
            FarmSource calldata item = farms[i];
            IFarmConnector connector = IFarmConnector(
                connectorRegistry.connectorOf(item.farm.stakingContract)
            );
            uint256 balance = connector.balanceOf(item.farm, address(sickle));
            // LP tokens remain owner-supplied zap inputs. Settings follow the
            // selected farm's actual stake, which is checked again after exit.
            if (balance == 0 || !connector.isStaked(item.farm, address(sickle)))
            {
                revert UnsupportedFarmAsset();
            }
            uint256 amount = item.withdraw.zap.removeLiquidityParams.lpAmountIn;
            if (amount == 0 || amount > balance) revert InvalidSource();
            sources[i].position.farm = item.farm;
            sources[i].full = amount == balance;
            PositionKey memory key = PositionKey(
                sickle, item.farm.stakingContract, item.farm.poolIndex
            );
            sources[i].exitDelay =
                exitDelaySettingsRegistry.getErc20ExitDelay(key);
            sources[i].compound =
                multiCompoundSettingsRegistry.getErc20Config(key);
        }
        for (uint256 i; i < nfts.length; ++i) {
            sources[farms.length + i] = _prepareNft(sickle, nfts[i]);
        }
        for (uint256 i; i < sources.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (_key(sources[i].position) == _key(sources[j].position)) {
                    revert DuplicateSource();
                }
            }
        }
    }

    function _prepareNft(
        Sickle sickle,
        NftFarmSource calldata item
    ) private view returns (MoveSourceSettings memory source) {
        address manager = address(item.position.nft);
        if (
            item.withdraw.zap.removeLiquidityParams.nft != item.position.nft
                || item.withdraw.zap.removeLiquidityParams.tokenId
                    != item.position.tokenId
        ) revert InvalidSource();
        _checkCustody(
            sickle,
            MovePosition(
                manager,
                item.position.tokenId,
                item.position.farm,
                address(0),
                0
            )
        );
        {
            INftLiquidityConnector connector =
                INftLiquidityConnector(connectorRegistry.connectorOf(manager));
            (,, uint128 liquidity) =
                connector.positionLiquidity(manager, item.position.tokenId);
            uint128 amount = item.withdraw.zap.removeLiquidityParams.liquidity;
            if (
                liquidity == 0 || amount == 0
                    || (amount != type(uint128).max && amount > liquidity)
            ) revert InvalidSource();

            source.full = (amount == liquidity || amount == type(uint128).max)
                && item.withdraw.zap.removeLiquidityParams.amount0Max
                    == type(uint128).max
                && item.withdraw.zap.removeLiquidityParams.amount1Max
                    == type(uint128).max;
        }
        NftPoolKey memory pool = _pool(manager, item.position.tokenId);
        source.position = MovePosition(
            manager,
            item.position.tokenId,
            item.position.farm,
            pool.poolAddress,
            pool.poolId
        );
        NftKey memory key =
            NftKey(sickle, item.position.nft, item.position.tokenId);
        source.exitDelay = exitDelaySettingsRegistry.getNftExitDelay(key);
        source.compound = multiCompoundSettingsRegistry.getNftConfig(key);
        // Reward overlays can differ from the owner's declared group farm.
        if (source.compound.enabled) {
            source.position.farm = source.compound.source;
        } else if (
            item.position.nft.ownerOf(item.position.tokenId) == address(sickle)
        ) {
            source.position.farm = Farm(manager, 0);
        }
        connectorRegistry.connectorOf(source.position.farm.stakingContract);
    }

    function _pool(
        address manager,
        uint256 tokenId
    ) private view returns (NftPoolKey memory pool) {
        // V4 connectors do not use a factory; V3/Algebra connectors do. Resolve
        // through the registered family instead of decoding positions() here.
        (bool ok, bytes memory data) =
            manager.staticcall(abi.encodeWithSignature("factory()"));
        address poolFactory =
            ok && data.length == 32 ? abi.decode(data, (address)) : address(0);
        pool = INftLiquidityConnector(connectorRegistry.connectorOf(manager))
            .positionPoolKey(poolFactory, manager, tokenId);
        if ((pool.poolAddress == address(0)) == (pool.poolId == bytes32(0))) {
            revert InvalidDestination();
        }
    }

    function _checkCustody(
        Sickle sickle,
        MovePosition memory position
    ) private view {
        if (
            position.tokenId == 0 || position.farm.stakingContract == address(0)
        ) revert InvalidSource();
        if (
            INonfungiblePositionManager(position.manager)
                    .ownerOf(position.tokenId) == address(sickle)
        ) return;
        INftFarmConnector connector = INftFarmConnector(
            connectorRegistry.connectorOf(position.farm.stakingContract)
        );
        if (!connector.isStaked(
                address(sickle),
                NftPosition(
                    position.farm,
                    INonfungiblePositionManager(position.manager),
                    position.tokenId
                )
            )) revert InvalidSource();
    }

    function positionPool(
        address manager,
        uint256 tokenId
    ) external view returns (NftPoolKey memory) {
        return _pool(manager, tokenId);
    }

    function applySettings(
        MoveSourceSettings[] calldata sources,
        MovePosition memory destination,
        bool existing
    ) external {
        Sickle sickle = Sickle(payable(address(this)));
        if (factory.admins(address(this)) == address(0)) revert OnlySickle();
        _requireMove();
        if (destination.manager != address(0)) {
            _checkCustody(sickle, destination);
            NftPoolKey memory pool =
                _pool(destination.manager, destination.tokenId);
            if (
                existing
                    || (destination.pool == address(0)
                        && destination.poolId == 0)
            ) {
                destination.pool = pool.poolAddress;
                destination.poolId = pool.poolId;
            } else if (
                pool.poolAddress != destination.pool
                    || pool.poolId != destination.poolId
            ) {
                revert InvalidDestination();
            }
        }
        uint256 donor = type(uint256).max;
        for (uint256 i; i < sources.length; ++i) {
            if (
                !sources[i].full
                    || _key(sources[i].position) == _key(destination)
            ) continue;
            _checkPolicySnapshot(sickle, sources[i]);
            _checkRemoved(sickle, sources[i]);
            if (donor == type(uint256).max) {
                donor = i;
            } else if (!_samePolicy(
                    sources[donor], sources[i], sources, destination, true
                )) {
                revert ConflictingSettings();
            }
        }
        if (donor == type(uint256).max) return;
        if (existing) {
            MoveSourceSettings memory target;
            target.position = destination;
            if (destination.manager == address(0)) {
                PositionKey memory key = PositionKey(
                    sickle,
                    destination.farm.stakingContract,
                    destination.farm.poolIndex
                );
                target.exitDelay =
                    exitDelaySettingsRegistry.getErc20ExitDelay(key);
                target.compound =
                    multiCompoundSettingsRegistry.getErc20Config(key);
            } else {
                NftKey memory key = NftKey(
                    sickle,
                    INonfungiblePositionManager(destination.manager),
                    destination.tokenId
                );
                target.exitDelay =
                    exitDelaySettingsRegistry.getNftExitDelay(key);
                target.compound =
                    multiCompoundSettingsRegistry.getNftConfig(key);
            }
            if (!_samePolicy(
                    sources[donor], target, sources, destination, false
                )) {
                revert ConflictingSettings();
            }
        }
        for (uint256 i; i < sources.length; ++i) {
            if (
                !sources[i].full
                    || _key(sources[i].position) == _key(destination)
            ) continue;
            if (sources[i].position.manager == address(0)) {
                PositionSettings memory disabled;
                positionSettingsRegistry.setPositionSettings(
                    PositionKey(
                        sickle,
                        sources[i].position.farm.stakingContract,
                        sources[i].position.farm.poolIndex
                    ),
                    disabled
                );
            } else {
                NftSettings memory disabled;
                nftSettingsRegistry.setNftSettings(
                    NftKey(
                        sickle,
                        INonfungiblePositionManager(
                            sources[i].position.manager
                        ),
                        sources[i].position.tokenId
                    ),
                    disabled
                );
            }
        }
    }

    /// @notice Authenticate the batch caller. Move does not copy opt-ins and
    /// does not retarget a destination that already has one, whether or not
    /// that destination is staked. No group redirect is recorded.
    function remapBatchTargets(
        MoveSourceSettings[][] calldata,
        MovePosition[] memory,
        bool[] calldata
    ) external view {
        if (factory.admins(address(this)) == address(0)) revert OnlySickle();
        _requireMove();
    }

    function _normalizeTarget(
        CompoundTarget memory target,
        MoveSourceSettings[] calldata sources,
        MovePosition memory destination
    ) private pure returns (CompoundTarget memory) {
        for (uint256 i; i < sources.length; ++i) {
            if (
                sources[i].full
                    && _sameTarget(target, _target(sources[i].position))
            ) {
                return _target(destination);
            }
        }
        return target;
    }

    function _checkRemoved(
        Sickle sickle,
        MoveSourceSettings calldata source
    ) private view {
        if (source.position.manager == address(0)) {
            IFarmConnector connector = IFarmConnector(
                connectorRegistry.connectorOf(
                    source.position.farm.stakingContract
                )
            );
            if (connector.balanceOf(source.position.farm, address(sickle)) != 0)
            {
                revert SourceNotRemoved();
            }
        } else {
            try INonfungiblePositionManager(source.position.manager)
                .ownerOf(source.position.tokenId) returns (
                address owner
            ) {
                if (owner != address(0)) {
                    INftLiquidityConnector connector = INftLiquidityConnector(
                        connectorRegistry.connectorOf(source.position.manager)
                    );
                    (,, uint128 liquidity) = connector.positionLiquidity(
                        source.position.manager, source.position.tokenId
                    );
                    (uint256 a, uint256 b) = connector.earnedFees(
                        source.position.manager,
                        source.position.pool,
                        source.position.tokenId
                    );
                    if (liquidity != 0 || a != 0 || b != 0) {
                        revert SourceNotRemoved();
                    }
                }
            } catch { }
        }
    }

    function _checkPolicySnapshot(
        Sickle sickle,
        MoveSourceSettings calldata source
    ) private view {
        uint8 delayMin;
        MultiCompoundConfig memory config;
        if (source.position.manager == address(0)) {
            PositionKey memory key = PositionKey(
                sickle,
                source.position.farm.stakingContract,
                source.position.farm.poolIndex
            );
            delayMin = exitDelaySettingsRegistry.getErc20ExitDelay(key);
            config = multiCompoundSettingsRegistry.getErc20Config(key);
        } else {
            NftKey memory key = NftKey(
                sickle,
                INonfungiblePositionManager(source.position.manager),
                source.position.tokenId
            );
            delayMin = exitDelaySettingsRegistry.getNftExitDelay(key);
            config = multiCompoundSettingsRegistry.getNftConfig(key);
        }
        if (
            delayMin != source.exitDelay
                || keccak256(abi.encode(config))
                    != keccak256(abi.encode(source.compound))
        ) {
            revert SettingsChanged();
        }
    }

    function _samePolicy(
        MoveSourceSettings memory a,
        MoveSourceSettings memory b,
        MoveSourceSettings[] calldata sources,
        MovePosition memory destination,
        bool normalizeSecond
    ) private pure returns (bool) {
        if (
            a.exitDelay != b.exitDelay
                || a.compound.enabled != b.compound.enabled
        ) return false;
        if (!a.compound.enabled) return true;
        CompoundTarget memory first = CompoundTarget(
            a.compound.target, a.compound.targetPoolId, a.compound.targetPool
        );
        CompoundTarget memory second = CompoundTarget(
            b.compound.target, b.compound.targetPoolId, b.compound.targetPool
        );
        first = _normalizeTarget(first, sources, destination);
        if (normalizeSecond) {
            second = _normalizeTarget(second, sources, destination);
        }
        return _sameTarget(first, second);
    }

    function _target(
        MovePosition memory position
    ) private pure returns (CompoundTarget memory) {
        return CompoundTarget(position.farm, position.poolId, position.pool);
    }

    function _sameTarget(
        CompoundTarget memory a,
        CompoundTarget memory b
    ) private pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    function _key(
        MovePosition memory position
    ) private pure returns (bytes32) {
        return position.manager == address(0)
            ? keccak256(abi.encode(uint8(0), position.farm))
            : keccak256(
                abi.encode(uint8(1), position.manager, position.tokenId)
            );
    }
}
