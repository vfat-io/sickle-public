// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    ReentrancyGuard
} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {
    IERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import { Sickle } from "contracts/Sickle.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {
    CrossFarmMoveStrategy
} from "contracts/strategies/CrossFarmMoveStrategy.sol";
import {
    Erc6909CrossFarmMoveStrategy
} from "contracts/strategies/Erc6909CrossFarmMoveStrategy.sol";
import {
    FarmSource,
    NftFarmSource,
    MoveToNft,
    MoveToExistingNft,
    MoveToFarm
} from "contracts/structs/CrossFarmMoveStructs.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import { NftAddLiquidity } from "contracts/structs/NftLiquidityStructs.sol";
import { SwapParams } from "contracts/structs/SwapStructs.sol";
import {
    MOVE_FAMILY_STANDARD,
    MOVE_FAMILY_ERC6909,
    DESTINATION_NEW_NFT,
    DESTINATION_EXISTING_NFT,
    DESTINATION_FARM,
    NewNftLeg,
    ExistingNftLeg,
    FarmLeg,
    LegOrder,
    LegOutcome,
    ICrossFarmMoveBatchStrategy
} from "contracts/structs/CrossFarmMoveBatchStructs.sol";

/// @notice One transaction, many destinations, for one Sickle owner.
/// @dev Each leg delegatecalls a pinned move strategy. `msg.sender` stays the
/// owner, so `getSickle` resolves that owner's Sickle. `address(this)` is
/// this contract, which is why it must be the whitelisted Sickle caller.
/// Immutables are read from the move bytecode. The move contracts have no
/// storage variables, so the delegatecall does not write this contract's
/// reentrancy slot. A normal CALL would set `msg.sender` to this contract
/// and resolve the wrong Sickle.
///
/// One leg is N sources into one destination. The transaction is many legs.
/// The same source is not withdrawn twice. One position is not split across
/// two destinations here. Native inputs use `address(0)` or the TransferLib
/// ETH sentinel, and the final sweep has to name one of them. An existing
/// NFT target harvest is held to the same token list as an NFT source.
contract CrossFarmMoveBatchStrategy is
    ReentrancyGuard,
    ICrossFarmMoveBatchStrategy
{
    CrossFarmMoveStrategy public immutable moveStrategy;
    Erc6909CrossFarmMoveStrategy public immutable erc6909MoveStrategy;
    address internal immutable self;

    error InvalidConfiguration();
    error DirectCallRequired();
    error InvalidBatchSize();
    error Expired();
    error InvalidSource();
    error InvalidDestination();
    error DuplicateSource();
    error DuplicateDestination();
    error DestinationIsSource();
    error DuplicateLeg();
    error OrphanLeg();
    error LegIndexOutOfRange();
    error WalletInputsNotSupported();
    error MissingSweepToken(address token);
    error UnsupportedFamily();
    error MintedIdReuse();

    struct Reservation {
        address[] nft;
        uint256[] id;
        bool[] manager;
        uint256 count;
    }

    struct UsedLegs {
        bool[] fresh;
        bool[] existing;
        bool[] farm;
        uint256 sources;
        uint256 existingDestinations;
        uint256 farmDestinations;
    }

    struct CrossScratch {
        bytes32[] sources;
        address[] existingNft;
        uint256[] existingId;
        bytes32[] farmDest;
        uint256[] farmDestLeg;
        bytes32[] farmSource;
        uint256[] farmSourceLeg;
        uint256 sourceN;
        uint256 existingN;
        uint256 farmDestN;
        uint256 farmSourceN;
    }

    constructor(
        CrossFarmMoveStrategy moveStrategy_,
        Erc6909CrossFarmMoveStrategy erc6909MoveStrategy_
    ) {
        if (address(moveStrategy_).code.length == 0) {
            revert InvalidConfiguration();
        }
        if (moveStrategy_.strategyAddress() != address(moveStrategy_)) {
            revert InvalidConfiguration();
        }
        if (address(erc6909MoveStrategy_) != address(0)) {
            if (address(erc6909MoveStrategy_).code.length == 0) {
                revert InvalidConfiguration();
            }
            if (
                erc6909MoveStrategy_.strategyAddress()
                        != address(erc6909MoveStrategy_)
                    || erc6909MoveStrategy_.factory() != moveStrategy_.factory()
                    || erc6909MoveStrategy_.connectorRegistry()
                        != moveStrategy_.connectorRegistry()
            ) revert InvalidConfiguration();
        }
        moveStrategy = moveStrategy_;
        erc6909MoveStrategy = erc6909MoveStrategy_;
        self = address(this);
    }

    /// @notice Move many destinations for `msg.sender` in one transaction.
    /// @dev Not payable. An empty `order` reverts. A failing leg reverts the
    /// whole call. `destinationId` 0 on a new NFT means the id could not be
    /// re-read. The move log still carries it.
    function move(
        LegOrder[] calldata order,
        NewNftLeg[] calldata newNfts,
        ExistingNftLeg[] calldata existingNfts,
        FarmLeg[] calldata farms,
        uint256 deadline
    ) external nonReentrant returns (LegOutcome[] memory outcomes) {
        return _move(order, newNfts, existingNfts, farms, deadline);
    }

    function _move(
        LegOrder[] calldata order,
        NewNftLeg[] calldata newNfts,
        ExistingNftLeg[] calldata existingNfts,
        FarmLeg[] calldata farms,
        uint256 deadline
    ) internal returns (LegOutcome[] memory outcomes) {
        if (address(this) != self) revert DirectCallRequired();
        uint256 length = order.length;
        if (length == 0) revert InvalidBatchSize();
        if (block.timestamp > deadline) revert Expired();

        Sickle sickle = moveStrategy.getSickle(msg.sender);
        _validate(order, newNfts, existingNfts, farms);
        outcomes = _executeAll(order, newNfts, existingNfts, farms, sickle);
    }

    function _executeAll(
        LegOrder[] calldata order,
        NewNftLeg[] calldata newNfts,
        ExistingNftLeg[] calldata existingNfts,
        FarmLeg[] calldata farms,
        Sickle sickle
    ) private returns (LegOutcome[] memory outcomes) {
        outcomes = new LegOutcome[](order.length);
        Reservation memory reserved = _reservation(order.length);
        for (uint256 i; i < order.length; ++i) {
            _guard(i, order, newNfts, existingNfts, farms, reserved);
            outcomes[i] = _apply(i, sickle, order, newNfts, existingNfts, farms);
            _note(reserved, order[i].kind, outcomes[i]);
        }
    }

    function _guard(
        uint256 legIndex,
        LegOrder[] calldata order,
        NewNftLeg[] calldata newNfts,
        ExistingNftLeg[] calldata existingNfts,
        FarmLeg[] calldata farms,
        Reservation memory reserved
    ) private pure {
        _rejectReserved(order[legIndex], newNfts, existingNfts, farms, reserved);
    }

    function _note(
        Reservation memory reserved,
        uint8 kind,
        LegOutcome memory outcome
    ) private pure {
        if (kind != DESTINATION_NEW_NFT) return;
        reserved.nft[reserved.count] = outcome.destination;
        reserved.id[reserved.count] = outcome.destinationId;
        reserved.manager[reserved.count] = outcome.destinationId == 0;
        ++reserved.count;
    }

    function _reservation(
        uint256 length
    ) private pure returns (Reservation memory reserved) {
        reserved.nft = new address[](length);
        reserved.id = new uint256[](length);
        reserved.manager = new bool[](length);
    }

    function _apply(
        uint256 legIndex,
        Sickle sickle,
        LegOrder[] calldata order,
        NewNftLeg[] calldata newNfts,
        ExistingNftLeg[] calldata existingNfts,
        FarmLeg[] calldata farms
    ) private returns (LegOutcome memory outcome) {
        uint8 kind = order[legIndex].kind;
        uint256 index = order[legIndex].index;
        if (kind == DESTINATION_NEW_NFT) {
            return _runNew(legIndex, sickle, newNfts[index]);
        }
        if (kind == DESTINATION_EXISTING_NFT) {
            return _runExisting(legIndex, sickle, existingNfts[index]);
        }
        return _runFarm(legIndex, sickle, farms[index]);
    }

    function _runNew(
        uint256 legIndex,
        Sickle sickle,
        NewNftLeg calldata leg
    ) private returns (LegOutcome memory outcome) {
        outcome.kind = DESTINATION_NEW_NFT;
        address nft = address(leg.move.deposit.nft);
        bool sameManager = _sourceOnManager(leg.move.nftSources, nft);
        (bool enumerable, uint256 supplyBefore) = _enumerableSupply(nft);
        _delegate(
            _target(leg.family),
            abi.encodeCall(
                CrossFarmMoveStrategy.moveToNft,
                (leg.move, leg.settings, leg.sweepTokens)
            )
        );
        outcome.destination = nft;
        outcome.destinationId =
            _newNftId(nft, sickle, sameManager, enumerable, supplyBefore);
        _emitLeg(
            legIndex,
            sickle,
            leg.family,
            DESTINATION_NEW_NFT,
            outcome.destination,
            outcome.destinationId,
            leg.move.farmSources,
            leg.move.nftSources
        );
    }

    function _runExisting(
        uint256 legIndex,
        Sickle sickle,
        ExistingNftLeg calldata leg
    ) private returns (LegOutcome memory outcome) {
        outcome.kind = DESTINATION_EXISTING_NFT;
        _delegate(
            _target(leg.family),
            abi.encodeCall(
                CrossFarmMoveStrategy.moveToExistingNft,
                (leg.move, leg.sweepTokens)
            )
        );
        outcome.destination = address(leg.move.target.position.nft);
        outcome.destinationId = leg.move.target.position.tokenId;
        _emitLeg(
            legIndex,
            sickle,
            leg.family,
            DESTINATION_EXISTING_NFT,
            outcome.destination,
            outcome.destinationId,
            leg.move.farmSources,
            leg.move.nftSources
        );
    }

    function _runFarm(
        uint256 legIndex,
        Sickle sickle,
        FarmLeg calldata leg
    ) private returns (LegOutcome memory outcome) {
        outcome.kind = DESTINATION_FARM;
        _delegate(
            _target(leg.family),
            abi.encodeCall(
                CrossFarmMoveStrategy.moveToFarm,
                (leg.move, leg.settings, leg.sweepTokens)
            )
        );
        outcome.destination = leg.move.deposit.farm.stakingContract;
        outcome.destinationId = leg.move.deposit.farm.poolIndex;
        _emitLeg(
            legIndex,
            sickle,
            leg.family,
            DESTINATION_FARM,
            outcome.destination,
            outcome.destinationId,
            leg.move.farmSources,
            leg.move.nftSources
        );
    }

    function _emitLeg(
        uint256 legIndex,
        Sickle sickle,
        uint8 family,
        uint8 kind,
        address destination,
        uint256 destinationId,
        FarmSource[] calldata farmSources,
        NftFarmSource[] calldata nftSources
    ) private {
        emit MoveLegExecuted(
            msg.sender,
            sickle,
            legIndex,
            family,
            kind,
            destination,
            destinationId,
            _hashSources(farmSources, nftSources)
        );
    }

    function _newNftId(
        address nft,
        Sickle sickle,
        bool sameManager,
        bool enumerable,
        uint256 supplyBefore
    ) private view returns (uint256 tokenId) {
        if (enumerable && !sameManager) {
            (bool okAfter, uint256 supplyAfter) = _enumerableSupply(nft);
            if (!okAfter || supplyAfter != supplyBefore + 1) return 0;
            (bool okId, uint256 id) = _tokenByIndex(nft, supplyBefore);
            return okId ? id : 0;
        }
        if (enumerable && sameManager) {
            (bool okAfter, uint256 supplyAfter) = _enumerableSupply(nft);
            if (!okAfter || supplyAfter == 0) return 0;
            (bool okId, uint256 id) = _tokenByIndex(nft, supplyAfter - 1);
            return okId ? id : 0;
        }
        return _connectorTokenId(nft, sickle);
    }

    function _rejectReserved(
        LegOrder calldata entry,
        NewNftLeg[] calldata newNfts,
        ExistingNftLeg[] calldata existingNfts,
        FarmLeg[] calldata farms,
        Reservation memory reserved
    ) private pure {
        if (reserved.count == 0) return;
        if (entry.kind == DESTINATION_NEW_NFT) {
            _rejectSources(newNfts[entry.index].move.nftSources, reserved);
        } else if (entry.kind == DESTINATION_EXISTING_NFT) {
            ExistingNftLeg calldata leg = existingNfts[entry.index];
            _rejectSources(leg.move.nftSources, reserved);
            _rejectOne(
                address(leg.move.target.position.nft),
                leg.move.target.position.tokenId,
                reserved
            );
        } else {
            _rejectSources(farms[entry.index].move.nftSources, reserved);
        }
    }

    function _rejectSources(
        NftFarmSource[] calldata sources,
        Reservation memory reserved
    ) private pure {
        for (uint256 i; i < sources.length; ++i) {
            _rejectOne(
                address(sources[i].position.nft),
                sources[i].position.tokenId,
                reserved
            );
        }
    }

    function _rejectOne(
        address nft,
        uint256 tokenId,
        Reservation memory reserved
    ) private pure {
        for (uint256 i; i < reserved.count; ++i) {
            if (reserved.nft[i] != nft) continue;
            if (reserved.manager[i] || reserved.id[i] == tokenId) {
                revert MintedIdReuse();
            }
        }
    }

    function _validate(
        LegOrder[] calldata order,
        NewNftLeg[] calldata newNfts,
        ExistingNftLeg[] calldata existingNfts,
        FarmLeg[] calldata farms
    ) private view {
        UsedLegs memory used;
        used.fresh = new bool[](newNfts.length);
        used.existing = new bool[](existingNfts.length);
        used.farm = new bool[](farms.length);
        for (uint256 i; i < order.length; ++i) {
            _claim(order[i], newNfts, existingNfts, farms, used);
        }
        _rejectOrphans(used.fresh);
        _rejectOrphans(used.existing);
        _rejectOrphans(used.farm);
        _checkCross(
            order,
            newNfts,
            existingNfts,
            farms,
            used.sources,
            used.existingDestinations,
            used.farmDestinations
        );
    }

    function _claim(
        LegOrder calldata entry,
        NewNftLeg[] calldata newNfts,
        ExistingNftLeg[] calldata existingNfts,
        FarmLeg[] calldata farms,
        UsedLegs memory used
    ) private view {
        uint256 index = entry.index;
        if (entry.kind == DESTINATION_NEW_NFT) {
            if (index >= newNfts.length) revert LegIndexOutOfRange();
            if (used.fresh[index]) revert DuplicateLeg();
            used.fresh[index] = true;
            used.sources += _checkNew(newNfts[index]);
        } else if (entry.kind == DESTINATION_EXISTING_NFT) {
            if (index >= existingNfts.length) revert LegIndexOutOfRange();
            if (used.existing[index]) revert DuplicateLeg();
            used.existing[index] = true;
            used.sources += _checkExisting(existingNfts[index]);
            ++used.existingDestinations;
        } else if (entry.kind == DESTINATION_FARM) {
            if (index >= farms.length) revert LegIndexOutOfRange();
            if (used.farm[index]) revert DuplicateLeg();
            used.farm[index] = true;
            used.sources += _checkFarm(farms[index]);
            ++used.farmDestinations;
        } else {
            revert InvalidDestination();
        }
    }

    function _rejectOrphans(
        bool[] memory used
    ) private pure {
        for (uint256 i; i < used.length; ++i) {
            if (!used[i]) revert OrphanLeg();
        }
    }

    function _checkNew(
        NewNftLeg calldata leg
    ) private view returns (uint256 sources) {
        _checkFamily(leg.family);
        MoveToNft calldata params = leg.move;
        sources = params.farmSources.length + params.nftSources.length;
        if (sources == 0) revert InvalidSource();
        if (params.tokensIn.length != 0 || params.amountsIn.length != 0) {
            revert WalletInputsNotSupported();
        }
        if (
            params.deposit.increase.tokensIn.length != 0
                || params.deposit.increase.amountsIn.length != 0
        ) revert WalletInputsNotSupported();
        NftAddLiquidity calldata mint =
        params.deposit.increase.zap.addLiquidityParams;
        if (
            address(params.deposit.nft) == address(0)
                || mint.nft != params.deposit.nft || mint.tokenId != 0
        ) revert InvalidDestination();
        _checkSourceList(params.farmSources, params.nftSources, leg.sweepTokens);
        _requireSweep(leg.sweepTokens, mint.pool.token0);
        _requireSweep(leg.sweepTokens, mint.pool.token1);
        _requireSwaps(leg.sweepTokens, params.deposit.increase.zap.swaps);
    }

    function _checkExisting(
        ExistingNftLeg calldata leg
    ) private view returns (uint256 sources) {
        _checkFamily(leg.family);
        MoveToExistingNft calldata params = leg.move;
        sources = params.farmSources.length + params.nftSources.length;
        if (sources == 0) revert InvalidSource();
        if (params.tokensIn.length != 0 || params.amountsIn.length != 0) {
            revert WalletInputsNotSupported();
        }
        if (
            params.target.increase.tokensIn.length != 0
                || params.target.increase.amountsIn.length != 0
        ) revert WalletInputsNotSupported();
        NftPosition calldata target = params.target.position;
        NftAddLiquidity calldata add =
        params.target.increase.zap.addLiquidityParams;
        if (
            target.tokenId == 0 || add.tokenId != target.tokenId
                || add.nft != target.nft
        ) revert InvalidDestination();
        for (uint256 i; i < params.nftSources.length; ++i) {
            if (
                params.nftSources[i].position.nft == target.nft
                    && params.nftSources[i].position.tokenId == target.tokenId
            ) revert DestinationIsSource();
        }
        _checkSourceList(params.farmSources, params.nftSources, leg.sweepTokens);
        _requireSweep(leg.sweepTokens, add.pool.token0);
        _requireSweep(leg.sweepTokens, add.pool.token1);
        _requireSwaps(leg.sweepTokens, params.target.increase.zap.swaps);
        // moveToExistingNft runs this harvest only when reward tokens are set.
        if (params.target.harvest.harvest.rewardTokens.length > 0) {
            _requireList(
                leg.sweepTokens, params.target.harvest.harvest.rewardTokens
            );
            _requireList(leg.sweepTokens, params.target.harvest.outputTokens);
            _requireSwaps(leg.sweepTokens, params.target.harvest.swaps);
        }
    }

    function _checkFarm(
        FarmLeg calldata leg
    ) private view returns (uint256 sources) {
        _checkFamily(leg.family);
        MoveToFarm calldata params = leg.move;
        sources = params.farmSources.length + params.nftSources.length;
        if (sources == 0) revert InvalidSource();
        if (params.tokensIn.length != 0 || params.amountsIn.length != 0) {
            revert WalletInputsNotSupported();
        }
        if (
            params.deposit.farm.stakingContract == address(0)
                || params.deposit.zap.addLiquidityParams.lpToken == address(0)
        ) revert InvalidDestination();
        _checkSourceList(params.farmSources, params.nftSources, leg.sweepTokens);
        _requireList(
            leg.sweepTokens, params.deposit.zap.addLiquidityParams.tokens
        );
        _requireSwaps(leg.sweepTokens, params.deposit.zap.swaps);
        _requireSweep(
            leg.sweepTokens, params.deposit.zap.addLiquidityParams.lpToken
        );
    }

    function _checkFamily(
        uint8 family
    ) private view {
        if (family == MOVE_FAMILY_STANDARD) return;
        if (
            family == MOVE_FAMILY_ERC6909
                && address(erc6909MoveStrategy) != address(0)
        ) return;
        revert UnsupportedFamily();
    }

    function _checkSourceList(
        FarmSource[] calldata farmSources,
        NftFarmSource[] calldata nftSources,
        address[] calldata sweepTokens
    ) private view {
        uint256 n = farmSources.length + nftSources.length;
        bytes32[] memory keys = new bytes32[](n);
        for (uint256 i; i < farmSources.length; ++i) {
            keys[i] = _farmKey(
                farmSources[i].farm.stakingContract,
                farmSources[i].farm.poolIndex
            );
            _rejectKey(keys, i);
            _sweepFarm(sweepTokens, farmSources[i]);
        }
        for (uint256 i; i < nftSources.length; ++i) {
            keys[farmSources.length + i] = _nftKey(
                address(nftSources[i].position.nft),
                nftSources[i].position.tokenId
            );
            _rejectKey(keys, farmSources.length + i);
            _sweepNft(sweepTokens, nftSources[i]);
        }
    }

    function _rejectKey(
        bytes32[] memory keys,
        uint256 index
    ) private pure {
        for (uint256 j; j < index; ++j) {
            if (keys[j] == keys[index]) revert DuplicateSource();
        }
    }

    function _checkCross(
        LegOrder[] calldata order,
        NewNftLeg[] calldata newNfts,
        ExistingNftLeg[] calldata existingNfts,
        FarmLeg[] calldata farms,
        uint256 sourceCount,
        uint256 existingDestCount,
        uint256 farmDestCount
    ) private pure {
        CrossScratch memory scratch;
        scratch.sources = new bytes32[](sourceCount);
        scratch.existingNft = new address[](existingDestCount);
        scratch.existingId = new uint256[](existingDestCount);
        scratch.farmDest = new bytes32[](farmDestCount);
        scratch.farmDestLeg = new uint256[](farmDestCount);
        scratch.farmSource = new bytes32[](sourceCount);
        scratch.farmSourceLeg = new uint256[](sourceCount);
        for (uint256 leg; leg < order.length; ++leg) {
            _crossOne(scratch, leg, order[leg], newNfts, existingNfts, farms);
        }
        _rejectCross(scratch);
    }

    function _crossOne(
        CrossScratch memory scratch,
        uint256 leg,
        LegOrder calldata entry,
        NewNftLeg[] calldata newNfts,
        ExistingNftLeg[] calldata existingNfts,
        FarmLeg[] calldata farms
    ) private pure {
        if (entry.kind == DESTINATION_NEW_NFT) {
            NewNftLeg calldata item = newNfts[entry.index];
            _takeSources(
                item.move.farmSources, item.move.nftSources, leg, scratch
            );
        } else if (entry.kind == DESTINATION_EXISTING_NFT) {
            _crossExisting(scratch, leg, existingNfts[entry.index]);
        } else {
            _crossFarm(scratch, leg, farms[entry.index]);
        }
    }

    function _crossExisting(
        CrossScratch memory scratch,
        uint256 leg,
        ExistingNftLeg calldata item
    ) private pure {
        _takeSources(item.move.farmSources, item.move.nftSources, leg, scratch);
        address nft = address(item.move.target.position.nft);
        uint256 tokenId = item.move.target.position.tokenId;
        for (uint256 j; j < scratch.existingN; ++j) {
            if (
                scratch.existingNft[j] == nft
                    && scratch.existingId[j] == tokenId
            ) revert DuplicateDestination();
        }
        scratch.existingNft[scratch.existingN] = nft;
        scratch.existingId[scratch.existingN] = tokenId;
        ++scratch.existingN;
    }

    function _crossFarm(
        CrossScratch memory scratch,
        uint256 leg,
        FarmLeg calldata item
    ) private pure {
        _takeSources(item.move.farmSources, item.move.nftSources, leg, scratch);
        bytes32 key = _farmKey(
            item.move.deposit.farm.stakingContract,
            item.move.deposit.farm.poolIndex
        );
        for (uint256 j; j < scratch.farmDestN; ++j) {
            if (scratch.farmDest[j] == key) revert DuplicateDestination();
        }
        scratch.farmDest[scratch.farmDestN] = key;
        scratch.farmDestLeg[scratch.farmDestN] = leg;
        ++scratch.farmDestN;
    }

    /// @dev Compares every destination with every source. Same-leg farm
    /// exit-and-reenter stays allowed. Every other farm overlap, and any
    /// existing-NFT target that is also an NFT source, reverts.
    function _rejectCross(
        CrossScratch memory scratch
    ) private pure {
        for (uint256 d; d < scratch.existingN; ++d) {
            _rejectNftTarget(
                scratch.sources,
                scratch.sourceN,
                scratch.existingNft[d],
                scratch.existingId[d]
            );
        }
        for (uint256 d; d < scratch.farmDestN; ++d) {
            for (uint256 s; s < scratch.farmSourceN; ++s) {
                if (
                    scratch.farmDest[d] == scratch.farmSource[s]
                        && scratch.farmDestLeg[d] != scratch.farmSourceLeg[s]
                ) revert DestinationIsSource();
            }
        }
    }

    function _takeSources(
        FarmSource[] calldata farmSources,
        NftFarmSource[] calldata nftSources,
        uint256 leg,
        CrossScratch memory scratch
    ) private pure {
        uint256 sourceN = scratch.sourceN;
        uint256 farmSourceN = scratch.farmSourceN;
        for (uint256 i; i < farmSources.length; ++i) {
            bytes32 key = _farmKey(
                farmSources[i].farm.stakingContract,
                farmSources[i].farm.poolIndex
            );
            _rejectSeen(scratch.sources, sourceN + i, key);
            scratch.sources[sourceN + i] = key;
            scratch.farmSource[farmSourceN + i] = key;
            scratch.farmSourceLeg[farmSourceN + i] = leg;
        }
        uint256 base = sourceN + farmSources.length;
        for (uint256 i; i < nftSources.length; ++i) {
            bytes32 key = _nftKey(
                address(nftSources[i].position.nft),
                nftSources[i].position.tokenId
            );
            _rejectSeen(scratch.sources, base + i, key);
            scratch.sources[base + i] = key;
        }
        scratch.sourceN = base + nftSources.length;
        scratch.farmSourceN = farmSourceN + farmSources.length;
    }

    function _rejectSeen(
        bytes32[] memory sources,
        uint256 index,
        bytes32 key
    ) private pure {
        for (uint256 j; j < index; ++j) {
            if (sources[j] == key) revert DuplicateSource();
        }
    }

    function _rejectNftTarget(
        bytes32[] memory sources,
        uint256 sourceN,
        address nft,
        uint256 tokenId
    ) private pure {
        bytes32 key = _nftKey(nft, tokenId);
        for (uint256 i; i < sourceN; ++i) {
            if (sources[i] == key) revert DestinationIsSource();
        }
    }

    function _sweepFarm(
        address[] calldata sweepTokens,
        FarmSource calldata source
    ) private pure {
        _requireList(
            sweepTokens, source.withdraw.zap.removeLiquidityParams.tokens
        );
        _requireList(sweepTokens, source.withdraw.tokensOut);
        _requireSwaps(sweepTokens, source.withdraw.zap.swaps);
        _requireList(sweepTokens, source.harvest.tokensOut);
        _requireSwaps(sweepTokens, source.harvest.swaps);
    }

    function _sweepNft(
        address[] calldata sweepTokens,
        NftFarmSource calldata source
    ) private view {
        _requireList(sweepTokens, source.withdraw.tokensOut);
        _requireSwaps(sweepTokens, source.withdraw.zap.swaps);
        _requireList(sweepTokens, source.harvest.harvest.rewardTokens);
        _requireList(sweepTokens, source.harvest.outputTokens);
        _requireSwaps(sweepTokens, source.harvest.swaps);
        NftPosition calldata position = source.position;
        if (
            source.withdraw.zap.removeLiquidityParams.nft != position.nft
                || source.withdraw.zap.removeLiquidityParams.tokenId
                    != position.tokenId
        ) revert InvalidSource();
        (bool found, address token0, address token1) =
            _underlying(address(position.nft), position.tokenId);
        if (!found) return;
        _requireSweep(sweepTokens, token0);
        _requireSweep(sweepTokens, token1);
    }

    function _underlying(
        address nft,
        uint256 tokenId
    ) private view returns (bool found, address token0, address token1) {
        (found, token0, token1) = _tokensFromPositions(nft, tokenId);
        if (found) return (true, token0, token1);
        return _tokensFromPool(nft, tokenId);
    }

    function _tokensFromPositions(
        address nft,
        uint256 tokenId
    ) private view returns (bool found, address token0, address token1) {
        (bool ok, bytes memory ret) = nft.staticcall(
            abi.encodeWithSelector(
                INonfungiblePositionManager.positions.selector, tokenId
            )
        );
        if (!ok) return (false, address(0), address(0));
        // Static ABI words. Tokens stay put when a family only adds a tail.
        // 10: Shadow and Machinex, tokens at 0 and 1.
        // 11: Algebra, tokens at 2 and 3 (352 bytes, not the V3 384).
        // 12+: Uniswap V3, Slipstream, Thena, Equalizer and Ramses, tokens at 2
        // and 3.
        uint256 words = ret.length / 32;
        if (words == 10) {
            return _tokenPair(ret, 0);
        }
        if (words == 11 || words >= 12) {
            return _tokenPair(ret, 2);
        }
    }

    function _tokenPair(
        bytes memory ret,
        uint256 token0Word
    ) private pure returns (bool, address, address) {
        return (
            true,
            address(uint160(uint256(_word(ret, token0Word)))),
            address(uint160(uint256(_word(ret, token0Word + 1))))
        );
    }

    function _tokensFromPool(
        address nft,
        uint256 tokenId
    ) private view returns (bool found, address token0, address token1) {
        ConnectorRegistry registry = moveStrategy.connectorRegistry();
        address connector = registry.connectorOf(nft);
        if (connector == address(0)) return (false, address(0), address(0));
        // Quickswap and Camelot call factory.poolByPair. address(0) reverts
        // and used to drop the underlying check. V4 ignores this argument.
        (bool ok, bytes memory ret) = connector.staticcall(
            abi.encodeCall(
                INftLiquidityConnector.positionPoolKey,
                (_nftFactory(nft), nft, tokenId)
            )
        );
        if (!ok || ret.length < 64) return (false, address(0), address(0));
        address poolAddress = address(uint160(uint256(_word(ret, 0))));
        bytes32 poolId = _word(ret, 1);
        if (poolId != bytes32(0)) {
            return _poolTokens(connector, address(0), poolId);
        }
        if (poolAddress != address(0)) {
            return _poolTokens(connector, poolAddress, bytes32(0));
        }
        return (false, address(0), address(0));
    }

    function _poolTokens(
        address connector,
        address pool,
        bytes32 poolId
    ) private view returns (bool found, address token0, address token1) {
        (bool ok, bytes memory ret) = connector.staticcall(
            abi.encodeCall(INftLiquidityConnector.poolInfo, (pool, poolId))
        );
        if (!ok || ret.length < 64) return (false, address(0), address(0));
        token0 = address(uint160(uint256(_word(ret, 0))));
        token1 = address(uint160(uint256(_word(ret, 1))));
        found = true;
    }

    function _nftFactory(
        address nft
    ) private view returns (address factory) {
        (bool ok, bytes memory ret) = nft.staticcall(
            abi.encodeWithSelector(INonfungiblePositionManager.factory.selector)
        );
        if (!ok || ret.length < 32) return address(0);
        factory = address(uint160(uint256(_word(ret, 0))));
    }

    function _word(
        bytes memory ret,
        uint256 index
    ) private pure returns (bytes32 word) {
        assembly {
            word := mload(add(add(ret, 32), mul(index, 32)))
        }
    }

    function _requireList(
        address[] calldata sweepTokens,
        address[] calldata tokens
    ) private pure {
        for (uint256 i; i < tokens.length; ++i) {
            _requireSweep(sweepTokens, tokens[i]);
        }
    }

    function _requireSwaps(
        address[] calldata sweepTokens,
        SwapParams[] calldata swaps
    ) private pure {
        for (uint256 i; i < swaps.length; ++i) {
            _requireSweep(sweepTokens, swaps[i].tokenIn);
            _requireSweep(sweepTokens, swaps[i].tokenOut);
        }
    }

    // NftZapLib and SwapLib use address(0). TransferLib and FeesLib also use
    // this sentinel. Either listing satisfies the same native balance.
    address private constant NATIVE_SENTINEL =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function _requireSweep(
        address[] calldata sweepTokens,
        address token
    ) private pure {
        bool native = _isNative(token);
        for (uint256 i; i < sweepTokens.length; ++i) {
            if (sweepTokens[i] == token) return;
            if (native && _isNative(sweepTokens[i])) return;
        }
        revert MissingSweepToken(token);
    }

    function _isNative(
        address token
    ) private pure returns (bool) {
        return token == address(0) || token == NATIVE_SENTINEL;
    }

    function _target(
        uint8 family
    ) private view returns (address) {
        if (family == MOVE_FAMILY_STANDARD) return address(moveStrategy);
        return address(erc6909MoveStrategy);
    }

    function _delegate(
        address target,
        bytes memory data
    ) private {
        (bool ok, bytes memory result) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _sourceOnManager(
        NftFarmSource[] calldata sources,
        address nft
    ) private pure returns (bool) {
        for (uint256 i; i < sources.length; ++i) {
            if (address(sources[i].position.nft) == nft) return true;
        }
        return false;
    }

    function _enumerableSupply(
        address nft
    ) private view returns (bool ok, uint256 supply) {
        (bool success, bytes memory ret) = nft.staticcall(
            abi.encodeWithSelector(IERC721Enumerable.totalSupply.selector)
        );
        if (!success || ret.length < 32) return (false, 0);
        supply = abi.decode(ret, (uint256));
        ok = true;
    }

    function _tokenByIndex(
        address nft,
        uint256 index
    ) private view returns (bool ok, uint256 tokenId) {
        (bool success, bytes memory ret) = nft.staticcall(
            abi.encodeWithSelector(
                IERC721Enumerable.tokenByIndex.selector, index
            )
        );
        if (!success || ret.length < 32) return (false, 0);
        tokenId = abi.decode(ret, (uint256));
        ok = true;
    }

    function _connectorTokenId(
        address nft,
        Sickle sickle
    ) private view returns (uint256 tokenId) {
        address connector = moveStrategy.connectorRegistry().connectorOf(nft);
        if (connector == address(0)) return 0;
        (bool success, bytes memory ret) = connector.staticcall(
            abi.encodeCall(
                INftLiquidityConnector.getTokenId, (nft, address(sickle))
            )
        );
        if (!success || ret.length < 32) return 0;
        tokenId = abi.decode(ret, (uint256));
    }

    function _hashSources(
        FarmSource[] calldata farmSources,
        NftFarmSource[] calldata nftSources
    ) private pure returns (bytes32) {
        bytes32[] memory keys =
            new bytes32[](farmSources.length + nftSources.length);
        for (uint256 i; i < farmSources.length; ++i) {
            keys[i] = _farmKey(
                farmSources[i].farm.stakingContract,
                farmSources[i].farm.poolIndex
            );
        }
        for (uint256 i; i < nftSources.length; ++i) {
            keys[farmSources.length + i] = _nftKey(
                address(nftSources[i].position.nft),
                nftSources[i].position.tokenId
            );
        }
        return keccak256(abi.encode(keys));
    }

    function _farmKey(
        address stakingContract,
        uint256 poolIndex
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(uint8(0), stakingContract, poolIndex));
    }

    function _nftKey(
        address nft,
        uint256 tokenId
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(uint8(1), nft, tokenId));
    }
}
