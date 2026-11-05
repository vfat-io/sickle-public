// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import {
    MovePosition,
    MoveSourceSettings
} from "contracts/structs/MoveSettingsStructs.sol";
import {
    FarmSource,
    NftFarmSource,
    MoveToNft,
    MoveToFarm,
    MoveToExistingNft,
    NftMove,
    FarmMove,
    ExistingNftMove,
    BatchMove
} from "contracts/structs/CrossFarmMoveStructs.sol";
import { NftSettings } from "contracts/structs/NftSettingsStructs.sol";
import {
    PositionSettings
} from "contracts/structs/PositionSettingsStructs.sol";
import {
    NftPoolKey,
    NftPoolInfo
} from "contracts/structs/NftLiquidityStructs.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { SwapParams } from "contracts/structs/SwapStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import { CompoundTarget } from "contracts/structs/MoveSettingsStructs.sol";

interface IMoveSettingsPreflight {
    function prepareSources(
        Sickle sickle,
        FarmSource[] calldata farms,
        NftFarmSource[] calldata nfts
    ) external view returns (MoveSourceSettings[] memory);
    function positionPool(
        address manager,
        uint256 tokenId
    ) external view returns (NftPoolKey memory);
    function connectorRegistry() external view returns (ConnectorRegistry);
    function hasFarmPosition(
        Sickle sickle,
        Farm calldata farm
    ) external view returns (bool);
    function remapBatchTargets(
        MoveSourceSettings[][] calldata sources,
        MovePosition[] calldata destinations,
        bool[] calldata fresh
    ) external view;
}

interface IMoveEntrypoints {
    function moveToNft(
        MoveToNft calldata,
        NftSettings calldata,
        address[] calldata
    ) external payable returns (uint256);
    function moveToFarm(
        MoveToFarm calldata,
        PositionSettings calldata,
        address[] calldata
    ) external payable;
    function moveToExistingNft(
        MoveToExistingNft calldata,
        address[] calldata
    ) external payable;
}

interface IMoveBatchContext {
    function strategyAddress() external view returns (address);
    function moveSettingsLib() external view returns (IMoveSettingsPreflight);
    function getSickle(
        address owner
    ) external view returns (Sickle);
}

/// @notice Batch preflight and immutable Move orchestration; never a Sickle
/// target or caller.
contract MoveBatchLib {
    address private immutable self = address(this);
    // Created by MoveSettingsLib: bind this dispatcher to that exact
    // generation.
    IMoveSettingsPreflight public immutable settingsLib =
        IMoveSettingsPreflight(msg.sender);
    error InvalidBatch();
    error Expired();
    error DirectCallRequired();
    error DuplicateSource();
    error ConflictingTargets();
    error InvalidMoveCall();
    error MissingSweepToken(address token);

    /// @dev Delegated only by Move. address(this) remains the implementation,
    /// msg.sender remains the wallet and all funds remain in its Sickle. Only
    /// immutable dependencies are read; no delegated storage writes occur.
    function batchMove(
        BatchMove calldata plan,
        uint256 deadline
    ) external returns (uint256[] memory tokenIds) {
        IMoveBatchContext context = IMoveBatchContext(address(this));
        if (
            address(this) == self || context.strategyAddress() != address(this)
                || address(context.moveSettingsLib()) != address(settingsLib)
        ) revert DirectCallRequired();
        uint256 count = plan.nftMoves.length + plan.farmMoves.length
            + plan.existingNftMoves.length;
        if (count == 0) revert InvalidBatch();
        if (block.timestamp > deadline) revert Expired();
        Sickle sickle = context.getSickle(msg.sender);
        (
            MoveSourceSettings[][] memory sources,
            MovePosition[] memory destinations,
            bool[] memory fresh
        ) = MoveBatchLib(self).validateBatch(sickle, plan);
        tokenIds = new uint256[](count);
        uint256 index;
        for (uint256 i; i < plan.nftMoves.length; ++i) {
            NftMove calldata leg = plan.nftMoves[i];
            uint256 id = abi.decode(
                _execute(
                    abi.encodeCall(
                        IMoveEntrypoints.moveToNft,
                        (leg.move, leg.settings, leg.sweepTokens)
                    )
                ),
                (uint256)
            );
            tokenIds[index] = id;
            destinations[index++].tokenId = id;
        }
        for (uint256 i; i < plan.farmMoves.length; ++i) {
            FarmMove calldata leg = plan.farmMoves[i];
            _execute(
                abi.encodeCall(
                    IMoveEntrypoints.moveToFarm,
                    (leg.move, leg.settings, leg.sweepTokens)
                )
            );
        }
        for (uint256 i; i < plan.existingNftMoves.length; ++i) {
            ExistingNftMove calldata leg = plan.existingNftMoves[i];
            _execute(
                abi.encodeCall(
                    IMoveEntrypoints.moveToExistingNft,
                    (leg.move, leg.sweepTokens)
                )
            );
        }
        for (uint256 i; i < count; ++i) {
            if (destinations[i].manager != address(0)) {
                NftPoolKey memory pool = settingsLib.positionPool(
                    destinations[i].manager, destinations[i].tokenId
                );
                destinations[i].pool = pool.poolAddress;
                destinations[i].poolId = pool.poolId;
            }
        }
        // Pool-less settings are valid. Recheck mappings against the actual
        // minted pools, which were unavailable during preflight.
        _validateTargets(sources, destinations);
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(settingsLib);
        data[0] = abi.encodeCall(
            IMoveSettingsPreflight.remapBatchTargets,
            (sources, destinations, fresh)
        );
        sickle.multicall(targets, data);
    }

    function _execute(
        bytes memory data
    ) private returns (bytes memory result) {
        bool success;
        (success, result) = address(this).delegatecall(data);
        if (!success) {
            assembly { revert(add(result, 32), mload(result)) }
        }
    }

    /// @notice Validate every typed leg before any withdrawal.
    function validateBatch(
        Sickle sickle,
        BatchMove calldata plan
    )
        external
        view
        returns (
            MoveSourceSettings[][] memory sources,
            MovePosition[] memory destinations,
            bool[] memory fresh
        )
    {
        uint256 count = plan.nftMoves.length + plan.farmMoves.length
            + plan.existingNftMoves.length;
        sources = new MoveSourceSettings[][](count);
        destinations = new MovePosition[](count);
        fresh = new bool[](count);
        uint256 index;
        for (uint256 i; i < plan.nftMoves.length; ++i) {
            (sources[index], destinations[index], fresh[index]) =
                _describeNft(sickle, plan.nftMoves[i]);
            ++index;
        }
        for (uint256 i; i < plan.farmMoves.length; ++i) {
            (sources[index], destinations[index], fresh[index]) =
                _describeFarm(sickle, plan.farmMoves[i]);
            ++index;
        }
        for (uint256 i; i < plan.existingNftMoves.length; ++i) {
            (sources[index], destinations[index]) =
                _describeExistingNft(sickle, plan.existingNftMoves[i]);
            ++index;
        }
        for (uint256 i; i < count; ++i) {
            for (uint256 j; j < i; ++j) {
                for (uint256 a; a < sources[i].length; ++a) {
                    for (uint256 b; b < sources[j].length; ++b) {
                        if (
                            _key(sources[i][a].position)
                                == _key(sources[j][b].position)
                        ) revert DuplicateSource();
                    }
                }
            }
        }
        _validateTargets(sources, destinations);
    }

    function _validateTargets(
        MoveSourceSettings[][] memory sources,
        MovePosition[] memory destinations
    ) private pure {
        for (uint256 i; i < destinations.length; ++i) {
            for (uint256 a; a < sources[i].length; ++a) {
                MoveSourceSettings memory source = sources[i][a];
                for (uint256 j; j < destinations.length; ++j) {
                    // Independent legs cannot reuse a source as a destination
                    // or consume another leg's new group identity.
                    if (
                        j != i
                            && (_key(destinations[j]) == _key(source.position)
                                || (source.full
                                    && _sameTarget(
                                        _target(source.position),
                                        _target(destinations[j])
                                    )))
                    ) revert ConflictingTargets();
                    if (!source.full) continue;
                    for (uint256 b; b < sources[j].length; ++b) {
                        if (
                            sources[j][b].full
                                && _sameTarget(
                                    _target(source.position),
                                    _target(sources[j][b].position)
                                )
                                && !_sameTarget(
                                    _target(destinations[i]),
                                    _target(destinations[j])
                                )
                        ) revert ConflictingTargets();
                    }
                }
            }
        }
    }

    function _describeNft(
        Sickle sickle,
        NftMove calldata leg
    )
        private
        view
        returns (
            MoveSourceSettings[] memory sources,
            MovePosition memory destination,
            bool fresh
        )
    {
        MoveToNft calldata move = leg.move;
        if (
            move.tokensIn.length != 0 || move.amountsIn.length != 0
                || move.deposit.increase.tokensIn.length != 0
                || move.deposit.increase.amountsIn.length != 0
        ) revert InvalidMoveCall();
        sources = settingsLib.prepareSources(
            sickle, move.farmSources, move.nftSources
        );
        destination = MovePosition(
            address(move.deposit.nft),
            0,
            move.deposit.farm,
            address(leg.settings.pool),
            leg.settings.poolId
        );
        fresh = true;
        _requireSweep(
            leg.sweepTokens,
            move.deposit.increase.zap.addLiquidityParams.pool.token0
        );
        _requireSweep(
            leg.sweepTokens,
            move.deposit.increase.zap.addLiquidityParams.pool.token1
        );
        _requireSwapSweeps(leg.sweepTokens, move.deposit.increase.zap.swaps);
        _sourceSweeps(
            settingsLib, leg.sweepTokens, move.farmSources, move.nftSources
        );
    }

    function _describeFarm(
        Sickle sickle,
        FarmMove calldata leg
    )
        private
        view
        returns (
            MoveSourceSettings[] memory sources,
            MovePosition memory destination,
            bool fresh
        )
    {
        MoveToFarm calldata move = leg.move;
        if (move.tokensIn.length != 0 || move.amountsIn.length != 0) {
            revert InvalidMoveCall();
        }
        sources = settingsLib.prepareSources(
            sickle, move.farmSources, move.nftSources
        );
        destination.farm = move.deposit.farm;
        fresh = !settingsLib.hasFarmPosition(sickle, move.deposit.farm);
        _requireSweeps(
            leg.sweepTokens, move.deposit.zap.addLiquidityParams.tokens
        );
        _requireSwapSweeps(leg.sweepTokens, move.deposit.zap.swaps);
        _sourceSweeps(
            settingsLib, leg.sweepTokens, move.farmSources, move.nftSources
        );
    }

    function _describeExistingNft(
        Sickle sickle,
        ExistingNftMove calldata leg
    )
        private
        view
        returns (
            MoveSourceSettings[] memory sources,
            MovePosition memory destination
        )
    {
        MoveToExistingNft calldata move = leg.move;
        if (
            move.tokensIn.length != 0 || move.amountsIn.length != 0
                || move.target.increase.tokensIn.length != 0
                || move.target.increase.amountsIn.length != 0
        ) revert InvalidMoveCall();
        sources = settingsLib.prepareSources(
            sickle, move.farmSources, move.nftSources
        );
        NftPoolKey memory pool = settingsLib.positionPool(
            address(move.target.position.nft), move.target.position.tokenId
        );
        destination = MovePosition(
            address(move.target.position.nft),
            move.target.position.tokenId,
            move.target.position.farm,
            pool.poolAddress,
            pool.poolId
        );
        _requireSweep(
            leg.sweepTokens,
            move.target.increase.zap.addLiquidityParams.pool.token0
        );
        _requireSweep(
            leg.sweepTokens,
            move.target.increase.zap.addLiquidityParams.pool.token1
        );
        _requireSwapSweeps(leg.sweepTokens, move.target.increase.zap.swaps);
        _requireSwapSweeps(leg.sweepTokens, move.target.harvest.swaps);
        _requireSweeps(
            leg.sweepTokens, move.target.harvest.harvest.rewardTokens
        );
        _requireSweeps(leg.sweepTokens, move.target.harvest.outputTokens);
        _requireSweeps(leg.sweepTokens, move.target.harvest.sweepTokens);
        _sourceSweeps(
            settingsLib, leg.sweepTokens, move.farmSources, move.nftSources
        );
    }

    function _sourceSweeps(
        IMoveSettingsPreflight settings,
        address[] memory sweeps,
        FarmSource[] memory farms,
        NftFarmSource[] memory nfts
    ) private view {
        for (uint256 i; i < farms.length; ++i) {
            _requireSweeps(
                sweeps, farms[i].withdraw.zap.removeLiquidityParams.tokens
            );
            _requireSweeps(sweeps, farms[i].withdraw.tokensOut);
            _requireSweeps(sweeps, farms[i].harvest.tokensOut);
            _requireSweeps(sweeps, farms[i].harvestSweepTokens);
            _requireSwapSweeps(sweeps, farms[i].harvest.swaps);
            _requireSwapSweeps(sweeps, farms[i].withdraw.zap.swaps);
        }
        for (uint256 i; i < nfts.length; ++i) {
            NftPoolKey memory pool = settings.positionPool(
                address(nfts[i].position.nft), nfts[i].position.tokenId
            );
            INftLiquidityConnector connector = INftLiquidityConnector(
                settings.connectorRegistry()
                    .connectorOf(address(nfts[i].position.nft))
            );
            NftPoolInfo memory info =
                connector.poolInfo(pool.poolAddress, pool.poolId);
            _requireSweep(sweeps, info.token0);
            _requireSweep(sweeps, info.token1);
            _requireSweeps(sweeps, nfts[i].withdraw.tokensOut);
            _requireSweeps(sweeps, nfts[i].harvest.harvest.rewardTokens);
            _requireSweeps(sweeps, nfts[i].harvest.outputTokens);
            _requireSweeps(sweeps, nfts[i].harvest.sweepTokens);
            _requireSwapSweeps(sweeps, nfts[i].harvest.swaps);
            _requireSwapSweeps(sweeps, nfts[i].withdraw.zap.swaps);
        }
    }

    function _requireSwapSweeps(
        address[] memory sweeps,
        SwapParams[] memory swaps
    ) private pure {
        for (uint256 i; i < swaps.length; ++i) {
            _requireSweep(sweeps, swaps[i].tokenIn);
            _requireSweep(sweeps, swaps[i].tokenOut);
        }
    }

    function _requireSweeps(
        address[] memory sweeps,
        address[] memory tokens
    ) private pure {
        for (uint256 i; i < tokens.length; ++i) {
            _requireSweep(sweeps, tokens[i]);
        }
    }

    function _requireSweep(
        address[] memory sweeps,
        address token
    ) private pure {
        for (uint256 i; i < sweeps.length; ++i) {
            if (sweeps[i] == token) return;
        }
        revert MissingSweepToken(token);
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
