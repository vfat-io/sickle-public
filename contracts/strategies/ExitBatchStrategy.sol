// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    ReentrancyGuard
} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Sickle } from "contracts/Sickle.sol";
import { StrategyModule } from "contracts/modules/StrategyModule.sol";
import { FarmStrategy } from "contracts/strategies/FarmStrategy.sol";
import { NftFarmStrategy } from "contracts/strategies/NftFarmStrategy.sol";
import { BinSettingsRegistryV2 } from "contracts/BinSettingsRegistryV2.sol";
import { BinKey } from "contracts/structs/BinSettingsStructs.sol";
import {
    BinFarmStrategyEvents
} from "contracts/events/BinFarmStrategyEvents.sol";
import { BinFarmStrategyFees } from "contracts/strategies/BinFarmStrategy.sol";
import { IBinFarmConnector } from "contracts/interfaces/IBinFarmConnector.sol";
import { IBinZapLib } from "contracts/interfaces/libraries/IBinZapLib.sol";
import {
    BinPosition,
    BinHarvest,
    BinWithdraw
} from "contracts/structs/BinFarmStrategyStructs.sol";
import { BinFarmStrategy } from "contracts/strategies/BinFarmStrategy.sol";
import { ExitCall, ExitKind } from "contracts/structs/ExitBatchStructs.sol";
import { NftFarmStrategyFees } from "contracts/strategies/NftFarmStrategy.sol";
import {
    NftFarmStrategyEvents
} from "contracts/events/NftFarmStrategyEvents.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { ITransferLib } from "contracts/interfaces/libraries/ITransferLib.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import { INftZapLib } from "contracts/interfaces/libraries/INftZapLib.sol";
import {
    NftPosition,
    NftHarvest,
    NftWithdraw
} from "contracts/structs/NftFarmStrategyStructs.sol";

/// @notice Executes one owner's same-chain exits atomically, in input order.
/// @dev Farm owner exits are delegated, preserving msg.sender. NFT/bin exits
/// compose existing Sickle libraries using each canonical strategy's fee key.
/// All custody remains in the owner's Sickle; existing target checks apply.
contract ExitBatchStrategy is
    ReentrancyGuard,
    NftFarmStrategyEvents,
    BinFarmStrategyEvents
{
    struct NftLibraries {
        ITransferLib transferLib;
        ISwapLib swapLib;
        IFeesLib feesLib;
        INftZapLib nftZapLib;
    }

    struct BinLibraries {
        ITransferLib transferLib;
        ISwapLib swapLib;
        IFeesLib feesLib;
        IBinZapLib binZapLib;
    }

    ITransferLib private immutable binTransfer;
    ISwapLib private immutable binSwap;
    IFeesLib private immutable binFees;
    IBinZapLib private immutable binZap;
    ITransferLib private immutable nftTransfer;
    ISwapLib private immutable nftSwap;
    IFeesLib private immutable nftFees;
    INftZapLib private immutable nftZap;
    FarmStrategy public immutable farmStrategy;
    NftFarmStrategy public immutable nftFarmStrategy;
    NftFarmStrategy public immutable erc6909FarmStrategy;
    BinFarmStrategy public immutable binFarmStrategy;
    address private immutable self;

    error InvalidConfiguration();
    error DirectCallRequired();
    error EmptyBatch();
    error Expired();
    error UnsupportedKind(ExitKind kind);
    error InvalidSelector(uint256 index);

    event ExitExecuted(
        address indexed owner,
        Sickle indexed sickle,
        uint256 indexed index,
        ExitKind kind,
        bytes32 callHash
    );

    /// @param farmStrategy_ Required canonical farm strategy.
    /// @param nftFarmStrategy_ NFT strategy, or zero when unsupported.
    /// @param erc6909FarmStrategy_ ERC-6909 strategy, or zero.
    /// @param binFarmStrategy_ Bin strategy, or zero when unsupported.
    /// @param libraries Existing NFT/ERC-6909 exit library bindings from their
    /// canonical deployment records. No NFT strategy replacement is required.
    /// @param binLibraries Existing Bin exit libraries from canonical records.
    constructor(
        FarmStrategy farmStrategy_,
        NftFarmStrategy nftFarmStrategy_,
        NftFarmStrategy erc6909FarmStrategy_,
        BinFarmStrategy binFarmStrategy_,
        NftLibraries memory libraries,
        BinLibraries memory binLibraries
    ) {
        if (address(farmStrategy_).code.length == 0) {
            revert InvalidConfiguration();
        }
        farmStrategy = farmStrategy_;
        _validateStrategy(address(nftFarmStrategy_));
        _validateStrategy(address(erc6909FarmStrategy_));
        _validateStrategy(address(binFarmStrategy_));
        if (
            address(nftFarmStrategy_) != address(0)
                || address(erc6909FarmStrategy_) != address(0)
        ) {
            if (
                address(libraries.transferLib).code.length == 0
                    || address(libraries.swapLib).code.length == 0
                    || address(libraries.feesLib).code.length == 0
                    || address(libraries.nftZapLib).code.length == 0
            ) revert InvalidConfiguration();
        }
        if (address(binFarmStrategy_) != address(0)) {
            if (
                address(binLibraries.transferLib).code.length == 0
                    || address(binLibraries.swapLib).code.length == 0
                    || address(binLibraries.feesLib).code.length == 0
                    || address(binLibraries.binZapLib).code.length == 0
            ) revert InvalidConfiguration();
            BinSettingsRegistryV2 settings = BinSettingsRegistryV2(
                address(binFarmStrategy_.binSettingsRegistry())
            );
            // A legacy registry cannot reconcile a separate exit caller.
            try settings.OWNER_EXIT_VERSION() returns (uint256 version) {
                if (
                    version != 2
                        || settings.factory() != farmStrategy_.factory()
                ) revert InvalidConfiguration();
            } catch {
                revert InvalidConfiguration();
            }
        }
        binTransfer = binLibraries.transferLib;
        binSwap = binLibraries.swapLib;
        binFees = binLibraries.feesLib;
        binZap = binLibraries.binZapLib;
        nftTransfer = libraries.transferLib;
        nftSwap = libraries.swapLib;
        nftFees = libraries.feesLib;
        nftZap = libraries.nftZapLib;
        nftFarmStrategy = nftFarmStrategy_;
        erc6909FarmStrategy = erc6909FarmStrategy_;
        binFarmStrategy = binFarmStrategy_;
        self = address(this);
    }

    modifier onlyDirectCall() {
        if (address(this) != self) revert DirectCallRequired();
        _;
    }

    /// @notice Bundle existing exit calldata for msg.sender's Sickle.
    /// @dev Nonpayable: exits spend existing Sickle positions, without wallet
    /// inputs. Any failure, including a later minimum, reverts every exit.
    /// Partial amounts retain the underlying exit entrypoint's semantics.
    function exit(
        ExitCall[] calldata calls,
        uint256 deadline
    ) external onlyDirectCall nonReentrant {
        if (calls.length == 0) revert EmptyBatch();
        if (block.timestamp > deadline) revert Expired();
        Sickle sickle = farmStrategy.getSickle(msg.sender);

        for (uint256 i; i < calls.length; ++i) {
            _validateCall(calls[i], i);
        }
        for (uint256 i; i < calls.length; ++i) {
            ExitCall calldata entry = calls[i];
            if (entry.kind == ExitKind.Nft || entry.kind == ExitKind.Erc6909) {
                _exitNft(sickle, _target(entry.kind), entry.data[4:]);
            } else if (entry.kind == ExitKind.Bin) {
                _exitBin(sickle, entry.data[4:]);
            } else {
                (bool success, bytes memory result) =
                    _target(entry.kind).delegatecall(entry.data);
                if (!success) {
                    assembly {
                        revert(add(result, 32), mload(result))
                    }
                }
            }
            emit ExitExecuted(
                msg.sender, sickle, i, entry.kind, keccak256(entry.data)
            );
        }
    }

    /// @dev Mirrors the canonical owner exit's orchestration and event order,
    /// including harvest sweep before withdrawal. No keeper/*For consent is
    /// borrowed: the Sickle was resolved exclusively from this transaction's
    /// owner. Owner exits leave NFT settings untouched, just like standalone.
    function _exitNft(
        Sickle sickle,
        address strategy,
        bytes calldata args
    ) private {
        (
            NftPosition memory position,
            NftHarvest memory harvest,
            NftWithdraw memory withdraw,
            address[] memory sweepTokens
        ) = abi.decode(args, (NftPosition, NftHarvest, NftWithdraw, address[]));

        bool swapRewards = harvest.swaps.length > 0;
        address[] memory targets = new address[](swapRewards ? 3 : 2);
        bytes[] memory data = new bytes[](targets.length);
        targets[0] = address(
            farmStrategy.connectorRegistry()
                .connectorOf(position.farm.stakingContract)
        );
        data[0] = abi.encodeCall(
            INftFarmConnector.claim,
            (
                position,
                harvest.harvest.rewardTokens,
                harvest.harvest.amount0Max,
                harvest.harvest.amount1Max,
                harvest.harvest.extraData
            )
        );
        if (swapRewards) {
            targets[1] = address(nftSwap);
            data[1] = abi.encodeCall(ISwapLib.swapMultiple, (harvest.swaps));
        }
        uint256 feeIndex = targets.length - 1;
        targets[feeIndex] = address(nftFees);
        data[feeIndex] = abi.encodeCall(
            IFeesLib.chargeFees,
            (
                strategy,
                NftFarmStrategyFees.Harvest,
                swapRewards
                    ? harvest.outputTokens
                    : harvest.harvest.rewardTokens
            )
        );
        sickle.multicall(targets, data);
        if (harvest.sweepTokens.length > 0) {
            _sweepNft(sickle, harvest.sweepTokens);
        }
        emit SickleHarvestedNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );

        _singleCall(
            sickle,
            farmStrategy.connectorRegistry()
                .connectorOf(position.farm.stakingContract),
            abi.encodeCall(
                INftFarmConnector.withdrawNft, (position, withdraw.extraData)
            )
        );
        emit SickleWithdrewNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );

        targets = new address[](2);
        data = new bytes[](2);
        targets[0] = address(nftZap);
        data[0] = abi.encodeCall(INftZapLib.zapOut, (withdraw.zap));
        targets[1] = address(nftFees);
        data[1] = abi.encodeCall(
            IFeesLib.chargeFees,
            (strategy, NftFarmStrategyFees.Withdraw, withdraw.tokensOut)
        );
        sickle.multicall(targets, data);
        _sweepNft(sickle, sweepTokens);
        emit SickleExitedNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    function _sweepNft(
        Sickle sickle,
        address[] memory tokens
    ) private {
        _singleCall(
            sickle,
            address(nftTransfer),
            abi.encodeCall(ITransferLib.transferTokensToUser, (tokens))
        );
    }

    function _singleCall(
        Sickle sickle,
        address target,
        bytes memory callData
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = target;
        data[0] = callData;
        sickle.multicall(targets, data);
    }

    /// @dev Same owner harvest/withdraw/sweep/settings order as the restored
    /// BinFarmStrategy. No strategy is delegated and no keeper consent is used.
    function _exitBin(
        Sickle sickle,
        bytes calldata args
    ) private {
        (
            BinPosition memory position,
            uint256[] memory ids,
            uint256[] memory amounts,
            BinHarvest memory harvest,
            BinWithdraw memory withdraw,
            address[] memory tokens
        ) = abi.decode(
            args,
            (
                BinPosition,
                uint256[],
                uint256[],
                BinHarvest,
                BinWithdraw,
                address[]
            )
        );
        _harvestBin(sickle, position, harvest);
        if (ids.length != amounts.length) {
            revert BinFarmStrategy.ArrayLengthMismatch();
        }
        if (
            address(position.lbPair)
                    != address(withdraw.zap.removeLiquidityParams.lbPair)
                || keccak256(abi.encode(ids, amounts))
                    != keccak256(
                        abi.encode(
                            withdraw.zap.removeLiquidityParams.ids,
                            withdraw.zap.removeLiquidityParams.amounts
                        )
                    )
        ) {
            revert BinFarmStrategy.InvalidParameters();
        }
        if (position.farm.stakingContract != address(0)) {
            _singleCall(
                sickle,
                farmStrategy.connectorRegistry()
                    .connectorOf(position.farm.stakingContract),
                abi.encodeCall(
                    IBinFarmConnector.withdraw,
                    (position, ids, amounts, withdraw.extraData)
                )
            );
        }
        _singleCall(
            sickle,
            address(binZap),
            abi.encodeCall(IBinZapLib.zapOut, (withdraw.zap))
        );
        _singleCall(
            sickle,
            address(binFees),
            abi.encodeCall(
                IFeesLib.chargeFees,
                (
                    address(binFarmStrategy),
                    BinFarmStrategyFees.Withdraw,
                    withdraw.tokensOut
                )
            )
        );
        _singleCall(
            sickle,
            address(binTransfer),
            abi.encodeCall(ITransferLib.transferTokensToUser, (tokens))
        );
        binFarmStrategy.binSettingsRegistry()
            .syncAfterOwnerWithdrawal(
                BinKey(
                    sickle,
                    position.lbPair,
                    position.farm.stakingContract,
                    position.farm.poolIndex
                )
            );
        emit SickleExitedBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex,
            ids,
            amounts
        );
    }

    function _harvestBin(
        Sickle sickle,
        BinPosition memory position,
        BinHarvest memory harvest
    ) private {
        if (position.farm.stakingContract == address(0)) return;
        bool swapRewards = harvest.swaps.length > 0;
        address[] memory targets = new address[](swapRewards ? 3 : 2);
        bytes[] memory data = new bytes[](targets.length);
        targets[0] = farmStrategy.connectorRegistry()
            .connectorOf(position.farm.stakingContract);
        data[0] = abi.encodeCall(
            IBinFarmConnector.claim, (position, harvest.harvest.extraData)
        );
        if (swapRewards) {
            targets[1] = address(binSwap);
            data[1] = abi.encodeCall(ISwapLib.swapMultiple, (harvest.swaps));
        }
        targets[targets.length - 1] = address(binFees);
        data[data.length - 1] = abi.encodeCall(
            IFeesLib.chargeFees,
            (
                address(binFarmStrategy),
                BinFarmStrategyFees.Harvest,
                swapRewards
                    ? harvest.outputTokens
                    : harvest.harvest.rewardTokens
            )
        );
        sickle.multicall(targets, data);
        if (harvest.sweepTokens.length > 0) {
            _singleCall(
                sickle,
                address(binTransfer),
                abi.encodeCall(
                    ITransferLib.transferTokensToUser, (harvest.sweepTokens)
                )
            );
        }
    }

    function _validateStrategy(
        address target
    ) private view {
        if (target == address(0)) return;
        if (
            target.code.length == 0
                || StrategyModule(target).factory() != farmStrategy.factory()
                || StrategyModule(target).connectorRegistry()
                    != farmStrategy.connectorRegistry()
        ) revert InvalidConfiguration();
    }

    function _validateCall(
        ExitCall calldata entry,
        uint256 index
    ) private view {
        _target(entry.kind);
        if (entry.data.length < 4) revert InvalidSelector(index);
        bytes4 selector = bytes4(entry.data[:4]);
        if (entry.kind == ExitKind.Farm) {
            if (
                selector == FarmStrategy.exit.selector
                    || selector == FarmStrategy.simpleExit.selector
            ) return;
        } else if (entry.kind == ExitKind.Nft || entry.kind == ExitKind.Erc6909)
        {
            if (selector == NftFarmStrategy.exit.selector) return;
        } else if (selector == BinFarmStrategy.exit.selector) {
            return;
        }
        revert InvalidSelector(index);
    }

    function _target(
        ExitKind kind
    ) private view returns (address target) {
        if (kind == ExitKind.Farm) {
            target = address(farmStrategy);
        } else if (kind == ExitKind.Nft) {
            target = address(nftFarmStrategy);
        } else if (kind == ExitKind.Erc6909) {
            target = address(erc6909FarmStrategy);
        } else {
            target = address(binFarmStrategy);
        }
        if (target == address(0)) revert UnsupportedKind(kind);
    }
}
