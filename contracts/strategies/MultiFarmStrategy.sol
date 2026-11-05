// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import {
    StrategyModule,
    SickleFactory,
    Sickle
} from "contracts/modules/StrategyModule.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IZapLib } from "contracts/interfaces/libraries/IZapLib.sol";
import { INftZapLib } from "contracts/interfaces/libraries/INftZapLib.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import { ITransferLib } from "contracts/interfaces/libraries/ITransferLib.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { FarmStrategyEvents } from "contracts/events/FarmStrategyEvents.sol";
import {
    NftFarmStrategyEvents
} from "contracts/events/NftFarmStrategyEvents.sol";
import {
    ClaimParams,
    NftClaimParams,
    MultiCompoundParams,
    NftMultiCompoundParams,
    MultiHarvestParams
} from "contracts/structs/MultiFarmStrategyStructs.sol";
import { IMultiAutomation } from "contracts/interfaces/IMultiAutomation.sol";
import {
    MultiCompoundSettingsRegistry,
    MultiCompoundConfig
} from "contracts/MultiCompoundSettingsRegistry.sol";
import { NftPoolKey } from "contracts/structs/NftLiquidityStructs.sol";
import { PositionKey } from "contracts/structs/PositionSettingsStructs.sol";
import { NftKey } from "contracts/structs/NftSettingsStructs.sol";

library MultiFarmStrategyFees {
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
    bytes4 constant Compound = bytes4(keccak256("FarmCompoundFee"));
    bytes4 constant CompoundFor = bytes4(keccak256("FarmCompoundForFee"));
}

contract MultiFarmStrategy is
    StrategyModule,
    FarmStrategyEvents,
    NftFarmStrategyEvents,
    IMultiAutomation
{
    struct Libraries {
        ITransferLib transferLib;
        ISwapLib swapLib;
        IFeesLib feesLib;
        IZapLib zapLib;
        INftZapLib nftZapLib;
    }

    ITransferLib public immutable transferLib;
    ISwapLib public immutable swapLib;
    IFeesLib public immutable feesLib;
    IZapLib public immutable zapLib;
    INftZapLib public immutable nftZapLib;
    MultiCompoundSettingsRegistry public immutable multiCompoundSettingsRegistry;
    address public immutable strategyAddress;

    // An automator-driven multi-compound must act on at least one source
    // position, so every call passes through the per-source consent check.
    error NoSourcePositions();
    // A source position carries no multi-compound opt-in in its settings.
    error MultiCompoundNotEnabled();
    // A source's pinned target differs from the requested deposit target.
    error TargetMismatch();
    // A source or target config points at a different V4-style PoolId than the
    // requested deposit target.
    error TargetPoolMismatch(bytes32 expectedPoolId, bytes32 actualPoolId);
    // The deposit position is not opted in as the multi-compound Target.
    error MultiCompoundTargetNotEnabled();
    // The zap would route liquidity into an NFT other than the validated
    // deposit position.
    error DepositPositionMismatch();

    /// @notice The ERC-20 multi-compound destination LP token is unset, so the
    /// zap would swap the harvested rewards and add no liquidity at all.
    error MissingDepositLpToken();

    /// @notice The keeper paired an enabled NFT source key with a farm the
    /// owner never recorded for it.
    error SourceFarmMismatch();

    /// @notice The source's declared destination pool disagrees with the
    /// destination's own. Distinguishes V3 pools sharing one position manager,
    /// where `targetPoolId` is always zero.
    error TargetPoolAddressMismatch(address expected, address actual);

    /// @notice A V3-style destination left its pool undeclared. Zero on both
    /// sides would compare equal and silently restore the ambiguity the
    /// declaration exists to remove.
    error DestinationPoolNotDeclared();

    /// @notice The multi-compound destination is no longer controlled by the
    /// Sickle, so consolidated rewards would be donated to its current owner.
    error DepositPositionNotControlled(address nftOwner);

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        MultiCompoundSettingsRegistry multiCompoundSettingsRegistry_,
        Libraries memory libraries
    ) StrategyModule(factory, connectorRegistry) {
        strategyAddress = address(this);
        transferLib = libraries.transferLib;
        swapLib = libraries.swapLib;
        feesLib = libraries.feesLib;
        zapLib = libraries.zapLib;
        nftZapLib = libraries.nftZapLib;
        multiCompoundSettingsRegistry = multiCompoundSettingsRegistry_;
    }

    /* External Functions */

    /**
     * @notice Compound multiple ERC20 and/or NFT farms into a single ERC20 farm
     * @param params The parameters for the compound operation
     * @param sweepTokens The tokens to sweep after the compound operation
     */
    function compoundMultiple(
        MultiCompoundParams calldata params,
        address[] calldata sweepTokens
    ) external {
        _compoundMultiple(
            getSickle(msg.sender),
            params,
            sweepTokens,
            MultiFarmStrategyFees.Compound
        );
    }

    /**
     * @notice Compound multiple farms into a single ERC20 farm on behalf of a
     * Sickle, callable only by the Sickle's approved address (Automation).
     * @dev Every source position must have been opted into multi-compounding by
     * the Sickle owner with `params.depositFarm` as its pinned target.
     * @param sickle The Sickle to compound for
     * @param params The parameters for the compound operation
     * @param sweepTokens The tokens to sweep after the compound operation
     */
    function compoundMultipleFor(
        Sickle sickle,
        MultiCompoundParams calldata params,
        address[] calldata sweepTokens
    ) external override onlyApproved(sickle) {
        // `ZapLib.zapIn()` treats a zero lpToken as "swaps only" and returns
        // before adding liquidity, and the no-op deposit connectors
        // (Curve pool, Merkl, HydrexMerkl) ignore both the Farm and the token
        // because the LP stays in the Sickle. The operation would then charge
        // the compound-for fee, run the keeper's swaps, emit a compound event
        // naming the pinned farm, and deposit nothing. Reject it before
        // harvesting rather than after the fee is taken.
        if (params.zap.addLiquidityParams.lpToken == address(0)) {
            revert MissingDepositLpToken();
        }
        _validateMultiCompoundFor(
            sickle,
            params.claims,
            params.nftClaims,
            params.depositFarm,
            bytes32(0),
            address(0)
        );
        _compoundMultiple(
            sickle, params, sweepTokens, MultiFarmStrategyFees.CompoundFor
        );
    }

    function _compoundMultiple(
        Sickle sickle,
        MultiCompoundParams calldata params,
        address[] calldata sweepTokens,
        bytes4 fee
    ) internal {
        _harvestErc20Positions(sickle, params.claims);
        _harvestNftPositions(sickle, params.nftClaims);

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);

        targets[0] = address(feesLib);
        data[0] = abi.encodeCall(
            IFeesLib.chargeFees, (strategyAddress, fee, params.rewardTokens)
        );

        targets[1] = address(zapLib);
        data[1] = abi.encodeCall(IZapLib.zapIn, (params.zap));

        address depositFarmConnector =
            connectorRegistry.connectorOf(params.depositFarm.stakingContract);
        targets[2] = depositFarmConnector;
        data[2] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                params.depositFarm,
                params.zap.addLiquidityParams.lpToken,
                params.depositExtraData
            )
        );

        targets[3] = address(transferLib);
        data[3] =
            abi.encodeCall(ITransferLib.transferTokensToUser, (sweepTokens));

        sickle.multicall(targets, data);

        _emitCompoundEvents(
            sickle, params.depositFarm, params.claims, params.nftClaims
        );
    }

    /**
     * @notice Compound multiple ERC20 and/or NFT farms into a single NFT farm
     * @param params The parameters for the compound operation
     * @param sweepTokens The tokens to sweep after the compound operation
     */
    function nftCompoundMultiple(
        NftMultiCompoundParams calldata params,
        address[] calldata sweepTokens
    ) external {
        _nftCompoundMultiple(
            getSickle(msg.sender),
            params,
            sweepTokens,
            MultiFarmStrategyFees.Compound,
            params.compoundInPlace
        );
    }

    /**
     * @notice Compound multiple farms into a single NFT farm on behalf of a
     * Sickle, callable only by the Sickle's approved address (Automation).
     * @dev Every source position must have been opted into multi-compounding by
     * the Sickle owner with the deposit position's farm as its pinned target,
     * and the same V4-style target PoolId when applicable. The deposit
     * position must itself carry the owner's `Target` opt-in, so a keeper
     * cannot consolidate into an NFT the owner never designated.
     * @param sickle The Sickle to compound for
     * @param params The parameters for the compound operation
     * @param sweepTokens The tokens to sweep after the compound operation
     */
    function nftCompoundMultipleFor(
        Sickle sickle,
        NftMultiCompoundParams calldata params,
        address[] calldata sweepTokens
    ) external override onlyApproved(sickle) {
        _checkHasSourcePositions(params.claims, params.nftClaims);
        (bytes32 targetPoolId, address targetPool) =
            _checkDepositTarget(sickle, params);
        _validateMultiCompoundFor(
            sickle,
            params.claims,
            params.nftClaims,
            params.depositPosition.farm,
            targetPoolId,
            targetPool
        );
        _nftCompoundMultiple(
            sickle,
            params,
            sweepTokens,
            MultiFarmStrategyFees.CompoundFor,
            params.compoundInPlace
        );
    }

    function _nftCompoundMultiple(
        Sickle sickle,
        NftMultiCompoundParams calldata params,
        address[] calldata sweepTokens,
        bytes4 fee,
        bool compoundInPlace
    ) internal {
        _harvestErc20Positions(sickle, params.claims);
        _harvestNftPositions(sickle, params.nftClaims);

        if (!compoundInPlace) {
            _withdrawNft(
                sickle, params.depositPosition, params.depositExtraData
            );
        }

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        targets[0] = address(feesLib);
        data[0] = abi.encodeCall(
            IFeesLib.chargeFees, (strategyAddress, fee, params.rewardTokens)
        );

        targets[1] = address(nftZapLib);
        data[1] = abi.encodeCall(INftZapLib.zapIn, (params.zap));

        targets[2] = address(transferLib);
        data[2] =
            abi.encodeCall(ITransferLib.transferTokensToUser, (sweepTokens));

        sickle.multicall(targets, data);

        if (!compoundInPlace) {
            _depositNft(sickle, params.depositPosition, params.depositExtraData);
        }

        _emitCompoundEvents(
            sickle, params.depositPosition.farm, params.claims, params.nftClaims
        );
    }

    /**
     * @notice Harvest multiple ERC20 and/or NFT farms
     * @param params The parameters for the harvest operation
     * @param sweepTokens The tokens to sweep after the harvest operation
     */
    function harvestMultiple(
        MultiHarvestParams calldata params,
        address[] memory sweepTokens
    ) public {
        Sickle sickle = getSickle(msg.sender);

        _harvestErc20Positions(sickle, params.claims);
        _harvestNftPositions(sickle, params.nftClaims);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        targets[0] = address(swapLib);
        data[0] = abi.encodeCall(ISwapLib.swapMultiple, (params.swaps));

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            IFeesLib.chargeFees,
            (strategyAddress, MultiFarmStrategyFees.Harvest, params.tokensOut)
        );

        targets[2] = address(transferLib);
        data[2] =
            abi.encodeCall(ITransferLib.transferTokensToUser, (sweepTokens));

        sickle.multicall(targets, data);

        _emitHarvestEvents(sickle, params.claims, params.nftClaims);
    }

    /* Private Functions */

    // Reverts unless every source position was opted into multi-compounding by
    // the Sickle owner with `target` as its pinned consolidation destination.
    function _validateMultiCompoundFor(
        Sickle sickle,
        ClaimParams[] calldata claims,
        NftClaimParams[] calldata nftClaims,
        Farm calldata target,
        bytes32 targetPoolId,
        address targetPool
    ) private view {
        _checkHasSourcePositions(claims, nftClaims);
        for (uint256 i; i < claims.length;) {
            Farm calldata claimFarm = claims[i].claimFarm;
            _checkSourceConfig(
                multiCompoundSettingsRegistry.getErc20Config(
                    PositionKey({
                        sickle: sickle,
                        stakingContract: claimFarm.stakingContract,
                        poolIndex: claimFarm.poolIndex
                    })
                ),
                target,
                targetPoolId,
                targetPool
            );
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < nftClaims.length;) {
            NftPosition calldata position = nftClaims[i].position;
            MultiCompoundConfig memory config = multiCompoundSettingsRegistry
                .getNftConfig(
                    NftKey({
                        sickle: sickle,
                        nftManager: position.nft,
                        tokenId: position.tokenId
                    })
                );
            _checkSourceConfig(config, target, targetPoolId, targetPool);
            // The NFT key carries no farm, so the keeper supplies
            // `position.farm` independently and `_harvestNftPositions()`
            // resolves the connector straight from it. Without this an enabled
            // key could be paired with any other connector-backed source —
            // e.g. a Linea vesting contract — and its rewards released and run
            // through the fee and swap path the owner never opted that source
            // into.
            if (
                config.source.stakingContract
                    != position.farm.stakingContract
                    || config.source.poolIndex != position.farm.poolIndex
            ) {
                revert SourceFarmMismatch();
            }
            unchecked {
                ++i;
            }
        }
    }

    function _checkHasSourcePositions(
        ClaimParams[] calldata claims,
        NftClaimParams[] calldata nftClaims
    ) private pure {
        if (claims.length == 0 && nftClaims.length == 0) {
            revert NoSourcePositions();
        }
    }

    // The Sickle owner records a source's opt-in in
    // MultiCompoundSettingsRegistry, pinned to the farm its rewards may be
    // consolidated into. For V4-style NFT targets this also pins the concrete
    // target PoolId, because the position manager covers multiple pools. A
    // disabled config means the position was never opted in. An NFT source's
    // config is migrated across a rebalance by the
    // registry's ISettingsModule hook, so the opt-in survives a tokenId change
    // without re-registration.
    function _checkSourceConfig(
        MultiCompoundConfig memory config,
        Farm calldata target,
        bytes32 targetPoolId,
        address targetPool
    ) private pure {
        if (!config.enabled) {
            revert MultiCompoundNotEnabled();
        }
        if (
            config.target.stakingContract != target.stakingContract
                || config.target.poolIndex != target.poolIndex
        ) {
            revert TargetMismatch();
        }
        if (config.targetPoolId != targetPoolId) {
            revert TargetPoolMismatch(config.targetPoolId, targetPoolId);
        }
        // For a bare V3 manager every pool shares one Farm and targetPoolId is
        // always zero, so the two checks above cannot tell two pools apart.
        // The owner declares the destination pool on both sides; requiring
        // them to agree restores the pool-level invariant the V4 path gets
        // from its derived PoolId.
        if (config.targetPool != targetPool) {
            revert TargetPoolAddressMismatch(config.targetPool, targetPool);
        }
    }

    // Reverts unless `params.depositPosition` is opted into multi-compound by
    // the Sickle owner with its own farm as the pinned target — i.e. it is a
    // valid consolidation destination — and the zap deposits liquidity into
    // exactly that NFT. The opt-in is keyed by (sickle, nft, tokenId) in
    // MultiCompoundSettingsRegistry — only the Sickle owner can write it, and
    // it is migrated across a rebalance — so a keeper cannot redirect the
    // consolidated rewards into another NFT in the target farm, foreign or not.
    function _checkDepositTarget(
        Sickle sickle,
        NftMultiCompoundParams calldata params
    )
        private
        view
        returns (bytes32 targetPoolId, address targetPool)
    {
        NftPosition calldata depositPosition = params.depositPosition;
        MultiCompoundConfig memory config =
            multiCompoundSettingsRegistry.getNftConfig(
                NftKey({
                    sickle: sickle,
                    nftManager: depositPosition.nft,
                    tokenId: depositPosition.tokenId
                })
            );
        if (!config.enabled) {
            revert MultiCompoundTargetNotEnabled();
        }
        if (
            config.target.stakingContract
                != depositPosition.farm.stakingContract
                || config.target.poolIndex != depositPosition.farm.poolIndex
        ) {
            revert TargetMismatch();
        }
        if (
            params.zap.addLiquidityParams.nft != depositPosition.nft
                || params.zap.addLiquidityParams.tokenId
                    != depositPosition.tokenId
        ) {
            revert DepositPositionMismatch();
        }
        // The config is keyed by (sickle, manager, tokenId) and survives the
        // NFT leaving the Sickle -- NftFarmStrategy.simpleWithdraw() transfers
        // it out without clearing multi-compound settings, and it can then be
        // sold on. compoundInPlace skips withdrawNft/depositNft and calls
        // NftZapLib.zapIn() directly, and adding liquidity to an existing
        // position is permissionless, so the rewards harvested from every
        // source position would land in an NFT the Sickle no longer controls.
        address nftOwner = depositPosition.nft.ownerOf(depositPosition.tokenId);
        if (nftOwner != address(sickle) && nftOwner != sickle.owner()) {
            // Custody-taking farms hold the NFT, so ownerOf reports the
            // staking contract and cannot answer; ask the farm instead.
            // Connectors either bind the answer to `user` -- via the farm's own
            // staker ledger, or via nft.ownerOf where the farm takes no custody
            // -- or return false. Hybra is the exception: its gauge publishes
            // nothing tying a tokenId to a depositor, so its answer is only
            // "staked by anyone". A stale Hybra target still fails, one step
            // later, when the withdraw leg is rejected by the gauge itself.
            address farmConnector = connectorRegistry.connectorOf(
                depositPosition.farm.stakingContract
            );
            bool staked = INftFarmConnector(farmConnector).isStaked(
                address(sickle), depositPosition
            );

            if (!staked) {
                revert DepositPositionNotControlled(nftOwner);
            }
        }

        targetPoolId = _positionPoolId(depositPosition);
        if (config.targetPoolId != targetPoolId) {
            revert TargetPoolMismatch(config.targetPoolId, targetPoolId);
        }
        // The destination's own opt-in declares which pool it is in. V3-style
        // managers cannot report this on-chain — their connectors need a pool
        // factory and return a zero PoolId — so it is owner-declared and used
        // only to require that every source agreed on the same destination
        // pool. V4-style destinations leave it zero and rely on targetPoolId.
        targetPool = config.targetPool;
        // A V3-style destination reports no PoolId, so `targetPool` is the
        // only thing distinguishing two pools under one manager. Leaving it
        // zero would make every source with an equally-unset field compare
        // equal, restoring the exact ambiguity the declaration removes — so a
        // destination whose PoolId is zero must declare its pool. V4-style
        // destinations carry a real PoolId and are exempt.
        if (targetPoolId == bytes32(0) && targetPool == address(0)) {
            revert DestinationPoolNotDeclared();
        }
    }

    function _positionPoolId(
        NftPosition calldata position
    ) private view returns (bytes32) {
        INftLiquidityConnector connector = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(position.nft))
        );

        // V4-style connectors derive a nonzero PoolId from the tokenId and do
        // not need a pool factory. Legacy V3-style connectors need the factory
        // only to recover a pool address and use bytes32(0) for PoolId, so a
        // zero-factory revert is treated as the legacy zero PoolId.
        try connector.positionPoolKey(
            address(0), address(position.nft), position.tokenId
        ) returns (
            NftPoolKey memory poolKey
        ) {
            return poolKey.poolId;
        } catch {
            return bytes32(0);
        }
    }

    function _harvestErc20Positions(
        Sickle sickle,
        ClaimParams[] calldata params
    ) private {
        uint256 arrayLength = params.length;
        address[] memory targets = new address[](arrayLength);
        bytes[] memory data = new bytes[](arrayLength);

        for (uint256 i; i < arrayLength;) {
            ClaimParams calldata claim = params[i];
            address farmConnector =
                connectorRegistry.connectorOf(claim.claimFarm.stakingContract);

            targets[i] = farmConnector;
            data[i] = abi.encodeCall(
                IFarmConnector.claim, (claim.claimFarm, claim.claimExtraData)
            );
            unchecked {
                ++i;
            }
        }

        sickle.multicall(targets, data);
    }

    function _harvestNftPositions(
        Sickle sickle,
        NftClaimParams[] calldata params
    ) private {
        uint256 arrayLength = params.length;
        address[] memory targets = new address[](arrayLength);
        bytes[] memory data = new bytes[](arrayLength);

        for (uint256 i; i < arrayLength;) {
            NftClaimParams calldata claim = params[i];
            address farmConnector = connectorRegistry.connectorOf(
                claim.position.farm.stakingContract
            );

            targets[i] = farmConnector;
            data[i] = abi.encodeCall(
                INftFarmConnector.claim,
                (
                    claim.position,
                    claim.harvest.rewardTokens,
                    claim.harvest.amount0Max,
                    claim.harvest.amount1Max,
                    claim.harvest.extraData
                )
            );
            unchecked {
                ++i;
            }
        }

        sickle.multicall(targets, data);
    }

    function _withdrawNft(
        Sickle sickle,
        NftPosition calldata position,
        bytes calldata extraData
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            INftFarmConnector.withdrawNft, (position, extraData)
        );

        sickle.multicall(targets, data);

        emit SickleWithdrewNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    function _depositNft(
        Sickle sickle,
        NftPosition calldata position,
        bytes calldata extraData
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            INftFarmConnector.depositExistingNft, (position, extraData)
        );

        sickle.multicall(targets, data);

        emit SickleDepositedNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    function _emitHarvestEvents(
        Sickle sickle,
        ClaimParams[] calldata claims,
        NftClaimParams[] calldata nftClaims
    ) private {
        for (uint256 i = 0; i < claims.length;) {
            emit SickleHarvested(
                sickle,
                claims[i].claimFarm.stakingContract,
                claims[i].claimFarm.poolIndex
            );
            unchecked {
                ++i;
            }
        }

        for (uint256 i = 0; i < nftClaims.length;) {
            emit SickleHarvestedNft(
                sickle,
                nftClaims[i].position.nft,
                nftClaims[i].position.tokenId,
                nftClaims[i].position.farm.stakingContract,
                nftClaims[i].position.farm.poolIndex
            );
            unchecked {
                ++i;
            }
        }
    }

    function _emitCompoundEvents(
        Sickle sickle,
        Farm calldata depositFarm,
        ClaimParams[] calldata claims,
        NftClaimParams[] calldata nftClaims
    ) private {
        for (uint256 i = 0; i < claims.length;) {
            emit SickleCompounded(
                sickle,
                claims[i].claimFarm.stakingContract,
                claims[i].claimFarm.poolIndex,
                depositFarm.stakingContract,
                depositFarm.poolIndex
            );
            unchecked {
                ++i;
            }
        }

        for (uint256 i = 0; i < nftClaims.length;) {
            emit SickleCompoundedNft(
                sickle,
                nftClaims[i].position.nft,
                nftClaims[i].position.tokenId,
                depositFarm.stakingContract,
                depositFarm.poolIndex
            );
            unchecked {
                ++i;
            }
        }
    }
}
