// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";

import {
    StrategyModule,
    SickleFactory,
    Sickle
} from "contracts/modules/StrategyModule.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IBinFarmConnector } from "contracts/interfaces/IBinFarmConnector.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import { ITransferLib } from "contracts/interfaces/libraries/ITransferLib.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import { IBinZapLib } from "contracts/interfaces/libraries/IBinZapLib.sol";
import { LbTokenTransferLib } from "contracts/libraries/LbTokenTransferLib.sol";
import { BinSettingsRegistry } from "contracts/BinSettingsRegistry.sol";
import { BinKey, BinSettings } from "contracts/structs/BinSettingsStructs.sol";
import {
    BinFarmStrategyEvents
} from "contracts/events/BinFarmStrategyEvents.sol";
import {
    BinPosition,
    BinDeposit,
    BinIncrease,
    BinWithdraw,
    BinHarvest,
    BinCompound,
    BinRebalance,
    BinMove,
    SimpleBinHarvest,
    BinZapIn,
    BinZapOut
} from "contracts/structs/BinFarmStrategyStructs.sol";

library BinFarmStrategyFees {
    bytes4 constant Deposit = bytes4(keccak256("FarmDepositFee"));
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
    bytes4 constant Compound = bytes4(keccak256("FarmCompoundFee"));
    bytes4 constant Withdraw = bytes4(keccak256("FarmWithdrawFee"));
    bytes4 constant HarvestFor = bytes4(keccak256("FarmHarvestForFee"));
    bytes4 constant CompoundFor = bytes4(keccak256("FarmCompoundForFee"));
    bytes4 constant RebalanceLow = bytes4(keccak256("RebalanceLowFee"));
    bytes4 constant RebalanceMid = bytes4(keccak256("RebalanceMidFee"));
    bytes4 constant RebalanceHigh = bytes4(keccak256("RebalanceHighFee"));
}

contract BinFarmStrategy is StrategyModule, BinFarmStrategyEvents {
    struct CurrentBins {
        uint256[] ids;
        uint256[] amounts;
    }

    error InvalidParameters();
    error KeeperWalletPullNotAllowed();
    error ArrayLengthMismatch();
    error ActiveIdOutsideBounds();

    struct Libraries {
        ITransferLib transferLib;
        ISwapLib swapLib;
        IFeesLib feesLib;
        IBinZapLib binZapLib;
        LbTokenTransferLib lbTokenTransferLib;
    }

    IBinZapLib private immutable binZapLib;
    ISwapLib private immutable swapLib;
    ITransferLib private immutable transferLib;
    IFeesLib private immutable feesLib;
    LbTokenTransferLib private immutable lbTokenTransferLib;
    BinSettingsRegistry public immutable binSettingsRegistry;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        BinSettingsRegistry binSettingsRegistry_,
        Libraries memory libraries
    ) StrategyModule(factory, connectorRegistry) {
        binZapLib = libraries.binZapLib;
        swapLib = libraries.swapLib;
        transferLib = libraries.transferLib;
        feesLib = libraries.feesLib;
        lbTokenTransferLib = libraries.lbTokenTransferLib;
        binSettingsRegistry = binSettingsRegistry_;
    }

    modifier onlyApprovedFor(
        Sickle sickle
    ) {
        _requireApproved(sickle);
        _;
    }

    /// @notice Deposits tokens into a Liquidity Book farm
    /// @param params Deposit parameters including farm and zap details
    /// @param settings Owner automation consent for the minted bins
    /// @param expectedBinIds Bin IDs from activeIdDesired and deltaIds; actual
    /// minted IDs may shift within idSlippage
    /// @param sweepTokens Tokens to sweep back to user
    /// @param approved Address approved for automation
    /// @param referralCode Referral code for new sickle deployment
    function deposit(
        BinDeposit calldata params,
        BinSettings calldata settings,
        uint256[] calldata expectedBinIds,
        address[] calldata sweepTokens,
        address approved,
        bytes32 referralCode
    ) external payable {
        if (
            address(params.lbPair)
                != address(params.increase.zap.addLiquidityParams.lbPair)
        ) {
            revert InvalidParameters();
        }
        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);

        bytes4 fee = params.increase.zap.swaps.length > 0
            ? BinFarmStrategyFees.Deposit
            : bytes4(0);

        _transferInTokens(sickle, params.increase, fee);

        (uint256[] memory mintedIds, uint256[] memory liquidityMinted) =
            _zapInAndGetMinted(sickle, params.increase.zap, expectedBinIds);

        if (params.farm.stakingContract != address(0)) {
            _depositToFarm(sickle, params, mintedIds, liquidityMinted);
        }

        _setSettingsAfterMint(
            sickle,
            params.lbPair,
            params.farm.stakingContract,
            params.farm.poolIndex,
            settings,
            mintedIds,
            liquidityMinted
        );

        _sweep(sickle, sweepTokens);

        emit SickleDepositedBin(
            sickle,
            params.lbPair,
            params.farm.stakingContract,
            params.farm.poolIndex,
            mintedIds,
            liquidityMinted
        );
    }

    /// @notice Increases an existing bin position
    /// @param position Current position details
    /// @param params Increase parameters
    /// @param expectedBinIds Bin IDs from activeIdDesired and deltaIds
    /// @param sweepTokens Tokens to sweep back to user
    function increase(
        BinPosition calldata position,
        BinIncrease calldata params,
        uint256[] calldata expectedBinIds,
        address[] calldata sweepTokens
    ) external payable {
        _increase(
            getSickle(msg.sender),
            position,
            params,
            expectedBinIds,
            sweepTokens,
            false
        );
    }

    function _increase(
        Sickle sickle,
        BinPosition calldata position,
        BinIncrease calldata params,
        uint256[] calldata expectedBinIds,
        address[] calldata sweepTokens,
        bool keeper
    ) private {
        if (
            address(position.lbPair)
                != address(params.zap.addLiquidityParams.lbPair)
        ) {
            revert InvalidParameters();
        }
        bytes4 fee = params.zap.swaps.length > 0
            ? BinFarmStrategyFees.Deposit
            : bytes4(0);

        if (!keeper) _transferInTokens(sickle, params, fee);

        (uint256[] memory mintedIds, uint256[] memory liquidityMinted) =
            _zapInAndGetMinted(sickle, params.zap, expectedBinIds);

        if (keeper) {
            binSettingsRegistry.validateMinted(
                _binKey(sickle, position), mintedIds
            );
        } else {
            binSettingsRegistry.includeAfterOwnerMint(
                _binKey(sickle, position), mintedIds, liquidityMinted
            );
        }

        if (position.farm.stakingContract != address(0)) {
            _depositToFarmDirect(
                sickle, position, mintedIds, liquidityMinted, params.extraData
            );
        }

        _sweep(sickle, sweepTokens);

        emit SickleIncreasedBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex,
            mintedIds,
            liquidityMinted
        );
    }

    /// @notice Withdraws from a bin farm position
    /// @param position Position details
    /// @param binIds Bin IDs to withdraw
    /// @param binAmounts Amounts to withdraw per bin
    /// @param params Withdrawal parameters
    /// @param sweepTokens Tokens to sweep back to user
    function withdraw(
        BinPosition calldata position,
        uint256[] calldata binIds,
        uint256[] calldata binAmounts,
        BinWithdraw calldata params,
        address[] calldata sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);

        bytes4 fee = params.zap.swaps.length > 0
            ? BinFarmStrategyFees.Withdraw
            : bytes4(0);

        _withdraw(sickle, position, binIds, binAmounts, params, fee, false);

        _sweep(sickle, sweepTokens);
        _clearSettings(sickle, position);

        emit SickleWithdrewBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex,
            binIds,
            binAmounts
        );
    }

    /// @notice Harvests rewards from a bin farm
    /// @param position Position details
    /// @param params Harvest parameters
    function harvest(
        BinPosition calldata position,
        BinHarvest calldata params
    ) external {
        Sickle sickle = getSickle(msg.sender);

        _harvest(sickle, position, params, BinFarmStrategyFees.Harvest);

        emit SickleHarvestedBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    /// @notice Compounds rewards back into the position
    /// @param position Position details
    /// @param params Compound parameters
    /// @param expectedBinIds Expected bin IDs for compounded liquidity
    /// @param sweepTokens Tokens to sweep back to user
    function compound(
        BinPosition calldata position,
        BinCompound calldata params,
        uint256[] calldata expectedBinIds,
        address[] calldata sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);

        (uint256[] memory mintedIds, uint256[] memory liquidityMinted) = _compound(
            sickle,
            position,
            params,
            expectedBinIds,
            sweepTokens,
            BinFarmStrategyFees.Compound
        );
        binSettingsRegistry.includeAfterOwnerMint(
            _binKey(sickle, position), mintedIds, liquidityMinted
        );

        emit SickleCompoundedBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex,
            mintedIds,
            liquidityMinted
        );
    }

    /// @notice Exits a bin farm position (harvest + withdraw)
    /// @param position Position details
    /// @param binIds Bin IDs to withdraw
    /// @param binAmounts Amounts to withdraw per bin
    /// @param harvestParams Harvest parameters
    /// @param withdrawParams Withdrawal parameters
    /// @param sweepTokens Tokens to sweep back to user
    function exit(
        BinPosition calldata position,
        uint256[] calldata binIds,
        uint256[] calldata binAmounts,
        BinHarvest calldata harvestParams,
        BinWithdraw calldata withdrawParams,
        address[] calldata sweepTokens
    ) external {
        _exit(
            getSickle(msg.sender),
            position,
            binIds,
            binAmounts,
            harvestParams,
            withdrawParams,
            sweepTokens,
            BinFarmStrategyFees.Harvest,
            false
        );
    }

    function _exit(
        Sickle sickle,
        BinPosition calldata position,
        uint256[] memory binIds,
        uint256[] memory binAmounts,
        BinHarvest calldata harvestParams,
        BinWithdraw calldata withdrawParams,
        address[] calldata sweepTokens,
        bytes4 harvestFee,
        bool useCurrentAmounts
    ) private {
        _harvest(sickle, position, harvestParams, harvestFee);
        _withdraw(
            sickle,
            position,
            binIds,
            binAmounts,
            withdrawParams,
            BinFarmStrategyFees.Withdraw,
            useCurrentAmounts
        );
        _sweep(sickle, sweepTokens);
        _clearSettings(sickle, position);
        emit SickleExitedBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex,
            binIds,
            binAmounts
        );
    }

    /// @notice Rebalances a bin position to new bins
    /// @param params Rebalance parameters
    /// @param newBinIds Expected new bin IDs after rebalance
    /// @param sweepTokens Tokens to sweep back to user
    function rebalance(
        BinRebalance calldata params,
        uint256[] calldata newBinIds,
        address[] calldata sweepTokens
    ) external {
        if (
            address(params.position.lbPair)
                != address(params.increase.zap.addLiquidityParams.lbPair)
        ) revert InvalidParameters();
        Sickle sickle = getSickle(msg.sender);
        CurrentBins memory current;
        (current.ids, current.amounts) = binSettingsRegistry.burnableBalances(
            address(sickle), params.position.lbPair, params.currentIds
        );
        binSettingsRegistry.validateOwnerFullWithdrawal(
            _binKey(sickle, params.position), current.ids, current.amounts
        );
        (uint256[] memory mintedIds, uint256[] memory mintedAmounts) = _rebalance(
            sickle,
            params,
            current,
            newBinIds,
            sweepTokens,
            BinFarmStrategyFees.Harvest
        );
        binSettingsRegistry.updateAfterOwnerRebalance(
            _binKey(sickle, params.position),
            mintedIds,
            mintedAmounts,
            params.increase.zap.addLiquidityParams
        );
    }

    function _rebalance(
        Sickle sickle,
        BinRebalance calldata params,
        CurrentBins memory current,
        uint256[] calldata newBinIds,
        address[] calldata sweepTokens,
        bytes4 harvestFee
    )
        private
        returns (uint256[] memory mintedIds, uint256[] memory newAmounts)
    {
        bytes4 withdrawFee = _getRebalanceFee(params.position.lbPair);

        _harvest(sickle, params.position, params.harvest, harvestFee);

        _withdraw(
            sickle,
            params.position,
            current.ids,
            current.amounts,
            params.withdraw,
            withdrawFee,
            true
        );

        (mintedIds, newAmounts) =
            _zapInAndGetMinted(sickle, params.increase.zap, newBinIds);

        if (params.position.farm.stakingContract != address(0)) {
            _depositToFarmDirect(
                sickle,
                params.position,
                mintedIds,
                newAmounts,
                params.increase.extraData
            );
        }

        _sweep(sickle, sweepTokens);

        emit SickleRebalancedBin(
            sickle,
            params.position.lbPair,
            params.position.farm.stakingContract,
            params.position.farm.poolIndex,
            current.ids,
            current.amounts,
            mintedIds,
            newAmounts
        );
    }

    /// @notice Moves a bin position to a different pool/farm
    /// @param params Move parameters including current and new position details
    /// @param settings Owner automation consent for the destination bins
    /// @param newBinIds Expected bin IDs in the new position
    /// @param sweepTokens Tokens to sweep back to user
    function move(
        BinMove calldata params,
        BinSettings calldata settings,
        uint256[] calldata newBinIds,
        address[] calldata sweepTokens
    ) external {
        if (
            address(params.deposit.lbPair)
                != address(
                    params.deposit.increase.zap.addLiquidityParams.lbPair
                )
        ) {
            revert InvalidParameters();
        }
        Sickle sickle = getSickle(msg.sender);
        (uint256[] memory ids, uint256[] memory amounts) = binSettingsRegistry.burnableBalances(
            address(sickle), params.position.lbPair, params.currentIds
        );
        binSettingsRegistry.validateOwnerFullWithdrawal(
            _binKey(sickle, params.position), ids, amounts
        );

        _harvest(
            sickle, params.position, params.harvest, BinFarmStrategyFees.Harvest
        );

        _withdraw(
            sickle,
            params.position,
            ids,
            amounts,
            params.withdraw,
            _getRebalanceFee(params.position.lbPair),
            true
        );

        (uint256[] memory mintedIds, uint256[] memory newAmounts) =
            _zapInAndGetMinted(sickle, params.deposit.increase.zap, newBinIds);

        if (params.deposit.farm.stakingContract != address(0)) {
            _depositToFarm(sickle, params.deposit, mintedIds, newAmounts);
        }

        _clearSettings(sickle, params.position);
        _setSettingsAfterMint(
            sickle,
            params.deposit.lbPair,
            params.deposit.farm.stakingContract,
            params.deposit.farm.poolIndex,
            settings,
            mintedIds,
            newAmounts
        );

        _sweep(sickle, sweepTokens);

        _emitMovedBin(sickle, params, ids, amounts, mintedIds, newAmounts);
    }

    function _emitMovedBin(
        Sickle sickle,
        BinMove calldata params,
        uint256[] memory currentIds,
        uint256[] memory currentAmounts,
        uint256[] memory mintedIds,
        uint256[] memory newAmounts
    ) private {
        emit SickleMovedBin(
            sickle,
            params.position.lbPair,
            params.position.farm.stakingContract,
            params.position.farm.poolIndex,
            params.deposit.lbPair,
            params.deposit.farm.stakingContract,
            params.deposit.farm.poolIndex,
            currentIds,
            currentAmounts,
            mintedIds,
            newAmounts
        );
    }

    /// @notice Simple harvest without swaps
    /// @param position Position details
    /// @param params Simple harvest parameters
    function simpleHarvest(
        BinPosition calldata position,
        SimpleBinHarvest calldata params
    ) external {
        Sickle sickle = getSickle(msg.sender);

        _simpleHarvest(sickle, position, params);

        emit SickleHarvestedBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    /// @notice Deposits existing LB tokens directly into the strategy
    /// @param position Position details (farm and lbPair)
    /// @param settings Owner automation consent for the deposited bins
    /// @param binIds Bin IDs to deposit
    /// @param binAmounts Amounts to deposit per bin
    /// @param extraData Additional data for farm deposit
    /// @param approved Address approved for automation
    /// @param referralCode Referral code for new sickle deployment
    function simpleDeposit(
        BinPosition calldata position,
        BinSettings calldata settings,
        uint256[] calldata binIds,
        uint256[] calldata binAmounts,
        bytes calldata extraData,
        address approved,
        bytes32 referralCode
    ) external {
        if (binIds.length != binAmounts.length) {
            revert ArrayLengthMismatch();
        }

        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);

        _transferInLbTokens(sickle, position.lbPair, binIds, binAmounts);

        if (position.farm.stakingContract != address(0)) {
            _depositToFarmDirect(
                sickle, position, binIds, binAmounts, extraData
            );
        }

        _setSettingsAfterMint(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex,
            settings,
            binIds,
            binAmounts
        );

        emit SickleDepositedBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex,
            binIds,
            binAmounts
        );
    }

    /// @notice Withdraws LB tokens directly to the user (without zapping)
    /// @param position Position details
    /// @param binIds Bin IDs to withdraw
    /// @param binAmounts Amounts to withdraw per bin
    /// @param extraData Additional data for farm withdrawal
    function simpleWithdraw(
        BinPosition calldata position,
        uint256[] calldata binIds,
        uint256[] calldata binAmounts,
        bytes calldata extraData
    ) external {
        if (binIds.length != binAmounts.length) {
            revert ArrayLengthMismatch();
        }

        Sickle sickle = getSickle(msg.sender);

        if (position.farm.stakingContract != address(0)) {
            _withdrawFromFarm(sickle, position, binIds, binAmounts, extraData);
        }

        _transferOutLbTokens(sickle, position.lbPair, binIds, binAmounts);
        _clearSettings(sickle, position);

        emit SickleWithdrewBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex,
            binIds,
            binAmounts
        );
    }

    /// @notice Claims rewards and returns bin shares without swapping.
    function simpleExit(
        BinPosition calldata position,
        uint256[] calldata binIds,
        uint256[] calldata binAmounts,
        SimpleBinHarvest calldata harvestParams,
        bytes calldata withdrawExtraData
    ) external {
        if (binIds.length != binAmounts.length) revert ArrayLengthMismatch();
        Sickle sickle = getSickle(msg.sender);
        _simpleHarvest(sickle, position, harvestParams);
        if (position.farm.stakingContract != address(0)) {
            _withdrawFromFarm(
                sickle, position, binIds, binAmounts, withdrawExtraData
            );
        }
        _transferOutLbTokens(sickle, position.lbPair, binIds, binAmounts);
        _clearSettings(sickle, position);
        emit SickleExitedBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex,
            binIds,
            binAmounts
        );
    }

    /* Keeper functions: Automation.executeFor routes these only after owner
       action consent and automator permission checks. */

    function depositFor(
        Sickle sickle,
        BinPosition calldata position,
        BinIncrease calldata params,
        uint256[] calldata expectedBinIds,
        address[] calldata sweepTokens
    ) external onlyApprovedFor(sickle) {
        BinKey memory key = _binKey(sickle, position);
        binSettingsRegistry.validateDepositFor(key);
        // Without an owner-controlled vault callback, keeper deposits may
        // consume only tokens the owner has already placed in the Sickle.
        if (params.tokensIn.length != 0 || params.amountsIn.length != 0) {
            revert KeeperWalletPullNotAllowed();
        }
        _increase(sickle, position, params, expectedBinIds, sweepTokens, true);
    }

    function harvestFor(
        Sickle sickle,
        BinPosition calldata position,
        BinHarvest calldata params
    ) external onlyApprovedFor(sickle) {
        binSettingsRegistry.validateHarvestFor(_binKey(sickle, position));
        _harvest(sickle, position, params, BinFarmStrategyFees.HarvestFor);
        emit SickleHarvestedBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    function compoundFor(
        Sickle sickle,
        BinPosition calldata position,
        BinCompound calldata params,
        uint256[] calldata expectedBinIds,
        address[] calldata sweepTokens
    ) external onlyApprovedFor(sickle) {
        BinKey memory key = _binKey(sickle, position);
        binSettingsRegistry.validateCompoundFor(key);
        (uint256[] memory mintedIds, uint256[] memory mintedAmounts) = _compound(
            sickle,
            position,
            params,
            expectedBinIds,
            sweepTokens,
            BinFarmStrategyFees.CompoundFor
        );
        binSettingsRegistry.validateMinted(key, mintedIds);
        emit SickleCompoundedBin(
            sickle,
            position.lbPair,
            position.farm.stakingContract,
            position.farm.poolIndex,
            mintedIds,
            mintedAmounts
        );
    }

    function exitFor(
        Sickle sickle,
        BinPosition calldata position,
        uint256[] calldata binIds,
        uint256[] calldata binAmounts,
        BinHarvest calldata harvestParams,
        BinWithdraw calldata withdrawParams,
        address[] calldata sweepTokens
    ) external onlyApprovedFor(sickle) {
        if (binIds.length != binAmounts.length) revert ArrayLengthMismatch();
        BinKey memory key = _binKey(sickle, position);
        (uint256[] memory ids, uint256[] memory amounts) = binSettingsRegistry.burnableBalances(
            address(sickle), position.lbPair, binIds
        );
        binSettingsRegistry.validateExitFor(key, ids, amounts);
        _exit(
            sickle,
            position,
            ids,
            amounts,
            harvestParams,
            withdrawParams,
            sweepTokens,
            BinFarmStrategyFees.HarvestFor,
            true
        );
    }

    function rebalanceFor(
        Sickle sickle,
        BinRebalance calldata params,
        uint256[] calldata newBinIds,
        address[] calldata sweepTokens
    ) external onlyApprovedFor(sickle) {
        _rebalanceFor(sickle, params, newBinIds, sweepTokens, 0, 0);
    }

    function boundedRebalanceFor(
        Sickle sickle,
        BinRebalance calldata params,
        uint256[] calldata newBinIds,
        address[] calldata sweepTokens,
        uint24 minActiveId,
        uint24 maxActiveId
    ) external onlyApprovedFor(sickle) {
        if (minActiveId > maxActiveId) revert ActiveIdOutsideBounds();
        _rebalanceFor(
            sickle, params, newBinIds, sweepTokens, minActiveId, maxActiveId
        );
    }

    function _rebalanceFor(
        Sickle sickle,
        BinRebalance calldata params,
        uint256[] calldata newBinIds,
        address[] calldata sweepTokens,
        uint24 minActiveId,
        uint24 maxActiveId
    ) private {
        if (
            address(params.position.lbPair)
                != address(params.increase.zap.addLiquidityParams.lbPair)
        ) revert InvalidParameters();
        BinKey memory key = _binKey(sickle, params.position);
        CurrentBins memory current;
        (current.ids, current.amounts) = binSettingsRegistry.burnableBalances(
            address(sickle), params.position.lbPair, params.currentIds
        );
        uint64 shiftTarget = binSettingsRegistry.validateRebalanceFor(
            key,
            current.ids,
            current.amounts,
            params.increase.zap.addLiquidityParams,
            minActiveId,
            maxActiveId
        );
        (uint256[] memory mintedIds, uint256[] memory mintedAmounts) = _rebalance(
            sickle,
            params,
            current,
            newBinIds,
            sweepTokens,
            BinFarmStrategyFees.HarvestFor
        );
        binSettingsRegistry.updateRangeAfterRebalance(
            key, mintedIds, mintedAmounts, shiftTarget
        );
    }

    function _binKey(
        Sickle sickle,
        BinPosition calldata position
    ) private pure returns (BinKey memory) {
        return BinKey({
            sickle: sickle,
            lbPair: position.lbPair,
            stakingContract: position.farm.stakingContract,
            poolIndex: position.farm.poolIndex
        });
    }

    function _clearSettings(
        Sickle sickle,
        BinPosition calldata position
    ) private {
        binSettingsRegistry.syncAfterOwnerWithdrawal(_binKey(sickle, position));
    }

    function _setSettingsAfterMint(
        Sickle sickle,
        ILBPair lbPair,
        address stakingContract,
        uint256 poolIndex,
        BinSettings calldata settings,
        uint256[] memory ids,
        uint256[] memory amounts
    ) private {
        binSettingsRegistry.setAfterMint(
            BinKey(sickle, lbPair, stakingContract, poolIndex),
            settings,
            ids,
            amounts
        );
    }

    function _transferInTokens(
        Sickle sickle,
        BinIncrease calldata params,
        bytes4 fee
    ) private {
        _singleMulticallValue(
            sickle,
            address(transferLib),
            abi.encodeCall(
                ITransferLib.transferTokensFromUser,
                (params.tokensIn, params.amountsIn, address(this), fee)
            ),
            msg.value
        );
    }

    /// @dev Existing Sickles have a void-returning multicall. Run swaps first,
    /// then snapshot only the bins at the resulting active ID before minting.
    /// BinZapLib verifies that the router mints exactly those bins and amounts.
    function _zapInAndGetMinted(
        Sickle sickle,
        BinZapIn calldata zap,
        uint256[] calldata expectedBinIds
    ) private returns (uint256[] memory mintedIds, uint256[] memory minted) {
        if (zap.swaps.length > 0) {
            _singleMulticall(
                sickle,
                address(swapLib),
                abi.encodeCall(ISwapLib.swapMultiple, (zap.swaps))
            );
        }

        ILBPair lbPair = zap.addLiquidityParams.lbPair;
        mintedIds = _idsAtActiveId(
            lbPair.getActiveId(), zap.addLiquidityParams.deltaIds
        );
        uint256[] memory beforeBalances = new uint256[](mintedIds.length);
        for (uint256 i; i < mintedIds.length; ++i) {
            beforeBalances[i] = lbPair.balanceOf(address(sickle), mintedIds[i]);
        }

        _singleMulticall(
            sickle,
            address(binZapLib),
            abi.encodeCall(
                IBinZapLib.addLiquidityChecked,
                (zap.addLiquidityParams, expectedBinIds)
            )
        );

        minted = new uint256[](mintedIds.length);
        for (uint256 i; i < mintedIds.length; ++i) {
            minted[i] = lbPair.balanceOf(address(sickle), mintedIds[i])
                - beforeBalances[i];
        }
    }

    function _idsAtActiveId(
        uint256 activeId,
        int256[] calldata deltaIds
    ) private pure returns (uint256[] memory ids) {
        ids = new uint256[](deltaIds.length);
        for (uint256 i; i < deltaIds.length; ++i) {
            int256 id = int256(activeId) + deltaIds[i];
            if (id < 0 || id > int256(uint256(type(uint24).max))) {
                revert InvalidParameters();
            }
            ids[i] = uint256(id);
        }
    }

    function _zapOut(
        Sickle sickle,
        BinZapOut memory zap
    ) private {
        _singleMulticall(
            sickle, address(binZapLib), abi.encodeCall(IBinZapLib.zapOut, (zap))
        );
    }

    function _depositToFarm(
        Sickle sickle,
        BinDeposit calldata params,
        uint256[] memory ids,
        uint256[] memory amounts
    ) private {
        BinPosition memory position =
            BinPosition({ farm: params.farm, lbPair: params.lbPair });
        _depositToFarmDirect(
            sickle, position, ids, amounts, params.increase.extraData
        );
    }

    function _depositToFarmDirect(
        Sickle sickle,
        BinPosition memory position,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory extraData
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        _singleMulticall(
            sickle,
            farmConnector,
            abi.encodeCall(
                IBinFarmConnector.deposit, (position, ids, amounts, extraData)
            )
        );
    }

    function _withdrawFromFarm(
        Sickle sickle,
        BinPosition calldata position,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes calldata extraData
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        _singleMulticall(
            sickle,
            farmConnector,
            abi.encodeCall(
                IBinFarmConnector.withdraw, (position, ids, amounts, extraData)
            )
        );
    }

    function _withdraw(
        Sickle sickle,
        BinPosition calldata position,
        uint256[] memory binIds,
        uint256[] memory binAmounts,
        BinWithdraw calldata params,
        bytes4 fee,
        bool useCurrentAmounts
    ) private {
        if (binIds.length != binAmounts.length) {
            revert ArrayLengthMismatch();
        }
        BinZapOut memory zap = params.zap;
        if (
            address(position.lbPair)
                != address(zap.removeLiquidityParams.lbPair)
        ) {
            revert InvalidParameters();
        }
        if (useCurrentAmounts) {
            zap.removeLiquidityParams.ids = binIds;
            zap.removeLiquidityParams.amounts = binAmounts;
        } else {
            if (
                keccak256(abi.encode(binIds, binAmounts))
                    != keccak256(
                        abi.encode(
                            zap.removeLiquidityParams.ids,
                            zap.removeLiquidityParams.amounts
                        )
                    )
            ) revert InvalidParameters();
        }

        if (position.farm.stakingContract != address(0)) {
            _withdrawFromFarm(
                sickle, position, binIds, binAmounts, params.extraData
            );
        }

        _zapOut(sickle, zap);

        _singleMulticall(
            sickle,
            address(feesLib),
            abi.encodeCall(
                IFeesLib.chargeFees, (address(this), fee, params.tokensOut)
            )
        );
    }

    function _harvest(
        Sickle sickle,
        BinPosition calldata position,
        BinHarvest calldata params,
        bytes4 fee
    ) private {
        if (position.farm.stakingContract == address(0)) {
            return;
        }

        if (params.swaps.length > 0) {
            _claimAndSwap(sickle, position, params, fee);
        } else {
            _claim(sickle, position, params.harvest, fee);
        }

        if (params.sweepTokens.length > 0) {
            _sweep(sickle, params.sweepTokens);
        }
    }

    function _simpleHarvest(
        Sickle sickle,
        BinPosition calldata position,
        SimpleBinHarvest calldata params
    ) private {
        if (position.farm.stakingContract == address(0)) {
            return;
        }
        _claim(sickle, position, params, BinFarmStrategyFees.Harvest);
        _sweep(sickle, params.rewardTokens);
    }

    function _claimAndSwap(
        Sickle sickle,
        BinPosition calldata position,
        BinHarvest calldata params,
        bytes4 fee
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IBinFarmConnector.claim, (position, params.harvest.extraData)
        );

        targets[1] = address(swapLib);
        data[1] = abi.encodeCall(ISwapLib.swapMultiple, (params.swaps));

        targets[2] = address(feesLib);
        data[2] = abi.encodeCall(
            IFeesLib.chargeFees, (address(this), fee, params.outputTokens)
        );

        sickle.multicall(targets, data);
    }

    function _claim(
        Sickle sickle,
        BinPosition calldata position,
        SimpleBinHarvest calldata params,
        bytes4 fee
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IBinFarmConnector.claim, (position, params.extraData)
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            IFeesLib.chargeFees, (address(this), fee, params.rewardTokens)
        );

        sickle.multicall(targets, data);
    }

    function _compound(
        Sickle sickle,
        BinPosition calldata position,
        BinCompound calldata params,
        uint256[] calldata expectedBinIds,
        address[] calldata sweepTokens,
        bytes4 fee
    )
        private
        returns (uint256[] memory mintedIds, uint256[] memory liquidityMinted)
    {
        if (
            address(position.lbPair)
                != address(params.zap.addLiquidityParams.lbPair)
        ) revert InvalidParameters();
        if (position.farm.stakingContract != address(0)) {
            _claim(sickle, position, params.harvest, fee);
        }

        (mintedIds, liquidityMinted) =
            _zapInAndGetMinted(sickle, params.zap, expectedBinIds);

        if (position.farm.stakingContract != address(0)) {
            _depositToFarmDirect(
                sickle,
                position,
                mintedIds,
                liquidityMinted,
                params.depositExtraData
            );
        }

        _sweep(sickle, sweepTokens);
    }

    function _sweep(
        Sickle sickle,
        address[] calldata sweepTokens
    ) private {
        _singleMulticall(
            sickle,
            address(transferLib),
            abi.encodeCall(ITransferLib.transferTokensToUser, (sweepTokens))
        );
    }

    function _transferInLbTokens(
        Sickle sickle,
        ILBPair lbPair,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) private {
        _singleMulticall(
            sickle,
            address(lbTokenTransferLib),
            abi.encodeCall(
                LbTokenTransferLib.transferLbTokensFromUser,
                (lbPair, ids, amounts)
            )
        );
    }

    function _transferOutLbTokens(
        Sickle sickle,
        ILBPair lbPair,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) private {
        _singleMulticall(
            sickle,
            address(lbTokenTransferLib),
            abi.encodeCall(
                LbTokenTransferLib.transferLbTokensToUser,
                (lbPair, ids, amounts)
            )
        );
    }

    function _singleMulticall(
        Sickle sickle,
        address target,
        bytes memory callData
    ) private {
        _singleMulticallValue(sickle, target, callData, 0);
    }

    function _singleMulticallValue(
        Sickle sickle,
        address target,
        bytes memory callData,
        uint256 value
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = target;
        data[0] = callData;
        sickle.multicall{ value: value }(targets, data);
    }

    function _getRebalanceFee(
        ILBPair pair
    ) private pure returns (bytes4) {
        uint16 binStep = pair.getBinStep();
        if (binStep <= 5) return BinFarmStrategyFees.RebalanceLow;
        if (binStep <= 30) return BinFarmStrategyFees.RebalanceMid;
        return BinFarmStrategyFees.RebalanceHigh;
    }
}
