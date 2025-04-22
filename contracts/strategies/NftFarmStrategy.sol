// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC721Enumerable } from
    "lib/openzeppelin-contracts/contracts/interfaces/IERC721Enumerable.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {
    IUniswapV3Pool,
    IUniswapV3PoolImmutables
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";

import {
    StrategyModule,
    SickleFactory,
    Sickle
} from "contracts/modules/StrategyModule.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { INftLiquidityConnector } from
    "contracts/interfaces/INftLiquidityConnector.sol";
import {
    INftSettingsRegistry,
    NftKey
} from "contracts/interfaces/INftSettingsRegistry.sol";
import { INftTransferLib } from
    "contracts/interfaces/libraries/INftTransferLib.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import { ITransferLib } from "contracts/interfaces/libraries/ITransferLib.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import { INftZapLib } from "contracts/interfaces/libraries/INftZapLib.sol";
import { INftSettingsLib } from
    "contracts/interfaces/libraries/INftSettingsLib.sol";
import { NftFarmStrategyEvents } from
    "contracts/events/NftFarmStrategyEvents.sol";
import { INftAutomation } from "contracts/interfaces/INftAutomation.sol";
import { NftZapIn } from "contracts/structs/NftZapStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import {
    NftPosition,
    NftDeposit,
    NftIncrease,
    NftWithdraw,
    NftHarvest,
    NftCompound,
    NftRebalance,
    NftMove,
    SimpleNftHarvest
} from "contracts/structs/NftFarmStrategyStructs.sol";
import { NftSettings } from "contracts/structs/NftSettingsStructs.sol";

library NftFarmStrategyFees {
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

contract NftFarmStrategy is
    StrategyModule,
    NftFarmStrategyEvents,
    INftAutomation
{
    uint256 constant REBALANCE_LOW_FEE_BPS = 500; // 0.05%
    uint256 constant REBALANCE_MID_FEE_BPS = 3000; // 0.3%

    error PleaseUseIncrease();
    error NftSupplyChanged();
    error NftSupplyDidntIncrease();

    struct Libraries {
        INftTransferLib nftTransferLib;
        ITransferLib transferLib;
        ISwapLib swapLib;
        IFeesLib feesLib;
        INftZapLib nftZapLib;
        INftSettingsLib nftSettingsLib;
    }

    INftTransferLib public immutable nftTransferLib;
    INftZapLib public immutable nftZapLib;
    ISwapLib public immutable swapLib;
    ITransferLib public immutable transferLib;
    IFeesLib public immutable feesLib;
    INftSettingsLib public immutable nftSettingsLib;

    INftSettingsRegistry public immutable nftSettingsRegistry;

    address public immutable strategyAddress;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        INftSettingsRegistry nftSettingsRegistry_,
        Libraries memory libraries
    ) StrategyModule(factory, connectorRegistry) {
        nftTransferLib = libraries.nftTransferLib;
        nftZapLib = libraries.nftZapLib;
        swapLib = libraries.swapLib;
        transferLib = libraries.transferLib;
        feesLib = libraries.feesLib;
        nftSettingsLib = libraries.nftSettingsLib;
        nftSettingsRegistry = nftSettingsRegistry_;
        strategyAddress = address(this);
    }

    /**
     * @notice Deposits tokens into the farm, creating a new NFT position.
     * @param params The parameters for the deposit.
     * @param settings The automation settings to be applied to the NFT.
     * @param sweepTokens The tokens to be swept at the end of the deposit.
     * @param approved The address approved to manage automation (used when
     * deploying a new Sickle only).
     * @param referralCode The referral code for tracking purposes (used when
     * deploying a new Sickle only).
     */
    function deposit(
        NftDeposit calldata params,
        NftSettings calldata settings,
        address[] calldata sweepTokens,
        address approved,
        bytes32 referralCode
    ) external payable {
        if (params.increase.zap.addLiquidityParams.tokenId != 0) {
            revert PleaseUseIncrease();
        }
        INftLiquidityConnector liquidityConnector = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(params.nft))
        );
        uint256 initialSupply =
            liquidityConnector.totalSupply(address(params.nft));

        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);

        _transferInTokens(sickle, params.increase);

        _zapIn(sickle, params.increase.zap);

        uint256 tokenId =
            liquidityConnector.getTokenId(address(params.nft), address(sickle));

        _depositNft(
            sickle,
            NftPosition({ farm: params.farm, nft: params.nft, tokenId: tokenId }),
            params.increase.extraData
        );

        _setNftSettings(sickle, params.nft, tokenId, settings);

        _sweep(sickle, sweepTokens);

        if (
            initialSupply >= liquidityConnector.totalSupply(address(params.nft))
        ) {
            revert NftSupplyDidntIncrease();
        }
    }

    /**
     * @notice Withdraws from the NFT farm and breaks the NFT position.
     * @param position The position details of the NFT to be withdrawn.
     * @param params The parameters for the withdrawal.
     * @param sweepTokens The tokens to be swept at the end of the withdrawal.
     */
    function withdraw(
        NftPosition calldata position,
        NftWithdraw calldata params,
        address[] calldata sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);

        bytes4 fee = params.zap.swaps.length > 0
            ? NftFarmStrategyFees.Withdraw
            : bytes4(0);

        _withdraw(sickle, position, params, fee);

        _sweep(sickle, sweepTokens);
    }

    /**
     * @notice Harvests rewards from the NFT farm.
     * @param position The position details of the NFT to be harvested.
     * @param params The parameters for the harvest.
     */
    function harvest(
        NftPosition calldata position,
        NftHarvest calldata params
    ) external {
        Sickle sickle = getSickle(msg.sender);

        _harvest(sickle, position, params, NftFarmStrategyFees.Harvest);
    }

    /**
     * @notice Compounds the NFT farm.
     * @param position The position details of the NFT to be compounded.
     * @param params The parameters for the compound.
     * @param inPlace Whether to compound in place (without withdrawing).
     * @param sweepTokens The tokens to be swept at the end of the compound.
     */
    function compound(
        NftPosition calldata position,
        NftCompound calldata params,
        bool inPlace, // Compound without withdrawing
        address[] calldata sweepTokens
    ) external nftSupplyUnchanged(position.nft) {
        Sickle sickle = getSickle(msg.sender);

        _compound(
            sickle,
            position,
            params,
            inPlace,
            sweepTokens,
            NftFarmStrategyFees.Compound
        );
    }

    /**
     * @notice Exits an NFT from the NFT farm (harvests and withdraws).
     * @param position The position details of the NFT to be exited.
     * @param harvestParams The parameters for the harvest.
     * @param withdrawParams The parameters for the withdrawal.
     * @param sweepTokens The tokens to be swept at the end of the exit.
     */
    function exit(
        NftPosition calldata position,
        NftHarvest calldata harvestParams,
        NftWithdraw calldata withdrawParams,
        address[] calldata sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);

        _exit(sickle, position, harvestParams, withdrawParams, sweepTokens);
    }

    /**
     * @notice Rebalances the NFT position.
     * @param params The parameters for the rebalance.
     * @param sweepTokens The tokens to be swept at the end of the rebalance.
     */
    function rebalance(
        NftRebalance calldata params,
        address[] calldata sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);

        _rebalance(sickle, params, sweepTokens, NftFarmStrategyFees.Harvest);
    }

    /**
     * @notice Withdraws from the current farm and deposits into a new farm.
     * @param params The parameters for the move.
     * @param settings The automation settings to be applied to the new NFT.
     * @param sweepTokens The tokens to be swept at the end of the move.
     */
    function move(
        NftMove calldata params,
        NftSettings calldata settings,
        address[] calldata sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);

        _harvest(
            sickle, params.position, params.harvest, NftFarmStrategyFees.Harvest
        );

        _withdraw(
            sickle,
            params.position,
            params.withdraw,
            _getRebalanceFee(
                params.position.nft, params.pool, params.position.tokenId
            )
        );

        _zapIn(sickle, params.deposit.increase.zap);

        uint256 tokenId = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(params.position.nft))
        ).getTokenId(address(params.position.nft), address(sickle));

        _depositNft(
            sickle,
            NftPosition({
                farm: params.deposit.farm,
                nft: params.deposit.nft,
                tokenId: tokenId
            }),
            params.deposit.increase.extraData
        );

        _setNftSettings(sickle, params.deposit.nft, tokenId, settings);

        _sweep(sickle, sweepTokens);

        _emitMoveEvent(
            sickle,
            params.position,
            params.deposit.nft,
            params.deposit.farm,
            tokenId
        );
    }

    // Required due to stack too deep error
    function _emitMoveEvent(
        Sickle sickle,
        NftPosition calldata positionFrom,
        INonfungiblePositionManager nftTo,
        Farm calldata farmTo,
        uint256 tokenId
    ) internal {
        emit SickleMovedNft(
            sickle,
            positionFrom.nft,
            positionFrom.tokenId,
            positionFrom.farm.stakingContract,
            positionFrom.farm.poolIndex,
            nftTo,
            tokenId,
            farmTo.stakingContract,
            farmTo.poolIndex
        );
    }

    /**
     * @notice Increases the NFT position.
     * @param position The position details of the NFT to be increased.
     * @param harvestParams The parameters for the harvest.
     * @param increaseParams The parameters for the increase.
     * @param inPlace Whether to increase in place (without withdrawing).
     * @param sweepTokens The tokens to be swept at the end of the increase.
     */
    function increase(
        NftPosition calldata position,
        NftHarvest calldata harvestParams,
        NftIncrease calldata increaseParams,
        bool inPlace, // Increase without withdrawing
        address[] calldata sweepTokens
    ) external payable nftSupplyUnchanged(position.nft) {
        Sickle sickle = getSickle(msg.sender);

        if (!inPlace) {
            _harvest(
                sickle, position, harvestParams, NftFarmStrategyFees.Harvest
            );
            _withdrawNft(sickle, position, increaseParams.extraData);
        }

        _transferInTokens(sickle, increaseParams);

        _zapIn(sickle, increaseParams.zap);

        if (!inPlace) {
            _depositNft(sickle, position, increaseParams.extraData);
        }

        _sweep(sickle, sweepTokens);

        emit SickleIncreasedNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    /**
     * @notice Decreases the NFT position.
     * @param position The position details of the NFT to be decreased.
     * @param harvestParams The parameters for the harvest.
     * @param withdrawParams The parameters for the withdrawal.
     * @param inPlace Whether to decrease in place (without withdrawing).
     * @param sweepTokens The tokens to be swept at the end of the decrease.
     */
    function decrease(
        NftPosition calldata position,
        NftHarvest calldata harvestParams,
        NftWithdraw calldata withdrawParams,
        bool inPlace,
        address[] calldata sweepTokens
    ) external nftSupplyUnchanged(position.nft) {
        Sickle sickle = getSickle(msg.sender);

        if (!inPlace) {
            _harvest(
                sickle, position, harvestParams, NftFarmStrategyFees.Harvest
            );

            _withdrawNft(sickle, position, withdrawParams.extraData);
        }

        bytes4 fee = withdrawParams.zap.swaps.length > 0
            ? NftFarmStrategyFees.Withdraw
            : bytes4(0);

        _zapOut(sickle, withdrawParams, fee);

        if (!inPlace) {
            _depositNft(sickle, position, withdrawParams.extraData);
        }

        _sweep(sickle, sweepTokens);

        _emitDecreaseEvent(sickle, position);
    }

    function _emitDecreaseEvent(
        Sickle sickle,
        NftPosition calldata position
    ) internal {
        emit SickleDecreasedNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    /* Simple actions (non-swap) */

    /**
     * @notice Deposits an NFT into the farm strategy.
     * @param position The position details of the NFT to be deposited.
     * @param extraData Additional data required for the deposit (optional).
     * @param settings The automation settings to be applied to the NFT.
     * @param approved The address approved to manage automation (used when
     * deploying a new Sickle only).
     * @param referralCode The referral code for tracking purposes (used when
     * deploying a new Sickle only).
     */
    function simpleDeposit(
        NftPosition calldata position,
        bytes calldata extraData,
        NftSettings calldata settings,
        address approved,
        bytes32 referralCode
    ) public {
        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);

        _transferInNft(sickle, position.nft, position.tokenId);

        _depositNft(sickle, position, extraData);

        _setNftSettings(sickle, position.nft, position.tokenId, settings);
    }

    /**
     * @notice Harvests rewards from the NFT farm without swapping.
     * @param position The position details of the NFT to be harvested.
     * @param params The parameters for the harvest.
     */
    function simpleHarvest(
        NftPosition calldata position,
        SimpleNftHarvest calldata params
    ) external {
        Sickle sickle = getSickle(msg.sender);

        _simpleHarvest(sickle, position, params);
    }

    /**
     * @notice Withdraws an NFT from the NFT farm.
     * @param position The position details of the NFT to be withdrawn.
     * @param extraData Additional data required for the withdrawal (optional).
     */
    function simpleWithdraw(
        NftPosition calldata position,
        bytes calldata extraData
    ) public {
        Sickle sickle = getSickle(msg.sender);

        _withdrawNft(sickle, position, extraData);

        _transferOutNft(sickle, position.nft, position.tokenId);

        emit SickleWithdrewNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    /**
     * @notice Exits an NFT from the NFT farm without swapping.
     * @param position The position details of the NFT to be exited.
     * @param harvestParams The parameters for the harvest.
     * @param withdrawExtraData Additional data required for the withdrawal
     * (optional).
     */
    function simpleExit(
        NftPosition calldata position,
        SimpleNftHarvest calldata harvestParams,
        bytes calldata withdrawExtraData
    ) public {
        Sickle sickle = getSickle(msg.sender);

        _simpleHarvest(sickle, position, harvestParams);

        _withdrawNft(sickle, position, withdrawExtraData);

        _transferOutNft(sickle, position.nft, position.tokenId);

        emit SickleExitedNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    /* Automation */

    /**
     * @notice Harvests rewards from the NFT farm.
     * Can only be called by the approved address on the Sickle.
     * @param position The position details of the NFT to be harvested.
     * @param params The parameters for the harvest.
     */
    function harvestFor(
        Sickle sickle,
        NftPosition calldata position,
        NftHarvest calldata params
    ) external override onlyApproved(sickle) {
        nftSettingsRegistry.validateHarvestFor(
            NftKey({
                sickle: sickle,
                nftManager: position.nft,
                tokenId: position.tokenId
            })
        );
        _harvest(sickle, position, params, NftFarmStrategyFees.HarvestFor);
    }

    /**
     * @notice Compounds the NFT farm.
     * Can only be called by the approved address on the Sickle.
     * @param position The position details of the NFT to be compounded.
     * @param params The parameters for the compound.
     * @param inPlace Whether to compound in place.
     * @param sweepTokens The tokens to be swept.
     */
    function compoundFor(
        Sickle sickle,
        NftPosition calldata position,
        NftCompound calldata params,
        bool inPlace,
        address[] calldata sweepTokens
    ) external override onlyApproved(sickle) {
        nftSettingsRegistry.validateCompoundFor(
            NftKey({
                sickle: sickle,
                nftManager: position.nft,
                tokenId: position.tokenId
            })
        );
        _compound(
            sickle,
            position,
            params,
            inPlace,
            sweepTokens,
            NftFarmStrategyFees.CompoundFor
        );
    }

    /**
     * @notice Exits an NFT from the NFT farm.
     * Can only be called by the approved address on the Sickle.
     * @param position The position details of the NFT to be exited.
     * @param harvestParams The parameters for the harvest.
     * @param withdrawParams The parameters for the withdrawal.
     * @param sweepTokens The tokens to be swept.
     */
    function exitFor(
        Sickle sickle,
        NftPosition calldata position,
        NftHarvest calldata harvestParams,
        NftWithdraw calldata withdrawParams,
        address[] calldata sweepTokens
    ) external override onlyApproved(sickle) {
        nftSettingsRegistry.validateExitFor(
            NftKey({
                sickle: sickle,
                nftManager: position.nft,
                tokenId: position.tokenId
            })
        );
        _exit(sickle, position, harvestParams, withdrawParams, sweepTokens);
    }

    /**
     * @notice Rebalances the NFT farm.
     * Can only be called by the approved address on the Sickle.
     * @param params The parameters for the rebalance.
     * @param sweepTokens The tokens to be swept.
     */
    function rebalanceFor(
        Sickle sickle,
        NftRebalance calldata params,
        address[] calldata sweepTokens
    ) external override onlyApproved(sickle) {
        nftSettingsRegistry.validateRebalanceFor(
            NftKey({
                sickle: sickle,
                nftManager: params.position.nft,
                tokenId: params.position.tokenId
            })
        );
        _rebalance(sickle, params, sweepTokens, NftFarmStrategyFees.HarvestFor);
    }

    /* Modifiers */

    modifier nftSupplyUnchanged(
        INonfungiblePositionManager nft
    ) {
        INftLiquidityConnector liquidityConnector =
            INftLiquidityConnector(connectorRegistry.connectorOf(address(nft)));
        uint256 initialSupply = liquidityConnector.totalSupply(address(nft));
        _;
        if (initialSupply != liquidityConnector.totalSupply(address(nft))) {
            revert NftSupplyChanged();
        }
    }

    /* Private */

    function _withdraw(
        Sickle sickle,
        NftPosition calldata position,
        NftWithdraw calldata params,
        bytes4 withdrawalFee
    ) internal {
        _withdrawNft(sickle, position, params.extraData);

        _zapOut(sickle, params, withdrawalFee);
    }

    function _harvest(
        Sickle sickle,
        NftPosition calldata position,
        NftHarvest calldata params,
        bytes4 fee
    ) private {
        if (params.swaps.length > 0) {
            _claimAndSwap(sickle, position, params);
        } else {
            _claim(sickle, position, params.harvest, fee);
        }

        if (params.sweepTokens.length > 0) {
            _sweep(sickle, params.sweepTokens);
        }

        emit SickleHarvestedNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    function _simpleHarvest(
        Sickle sickle,
        NftPosition calldata position,
        SimpleNftHarvest calldata params
    ) private {
        _claim(sickle, position, params, NftFarmStrategyFees.Harvest);

        _sweep(sickle, params.rewardTokens);

        emit SickleHarvestedNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    function _compound(
        Sickle sickle,
        NftPosition calldata position,
        NftCompound calldata params,
        bool inPlace,
        address[] calldata sweepTokens,
        bytes4 fee
    ) private {
        _claim(sickle, position, params.harvest, fee);

        if (!inPlace) {
            _withdrawNft(sickle, position, params.harvest.extraData);
        }

        _zapIn(sickle, params.zap);

        if (!inPlace) {
            _depositNft(sickle, position, params.harvest.extraData);
        }

        _sweep(sickle, sweepTokens);

        emit SickleCompoundedNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    function _exit(
        Sickle sickle,
        NftPosition calldata position,
        NftHarvest calldata harvestParams,
        NftWithdraw calldata withdrawParams,
        address[] calldata sweepTokens
    ) private {
        _harvest(sickle, position, harvestParams, NftFarmStrategyFees.Harvest);

        _withdraw(
            sickle, position, withdrawParams, NftFarmStrategyFees.Withdraw
        );

        _sweep(sickle, sweepTokens);

        emit SickleExitedNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    function _rebalance(
        Sickle sickle,
        NftRebalance calldata params,
        address[] calldata sweepTokens,
        bytes4 harvestFee
    ) private {
        _harvest(sickle, params.position, params.harvest, harvestFee);

        _withdraw(
            sickle,
            params.position,
            params.withdraw,
            _getRebalanceFee(
                params.position.nft, params.pool, params.position.tokenId
            )
        );

        _zapIn(sickle, params.increase.zap);

        _resetNftSettings(sickle, params.position.nft, params.position.tokenId);

        uint256 tokenId = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(params.position.nft))
        ).getTokenId(address(params.position.nft), address(sickle));

        _depositNft(
            sickle,
            NftPosition({
                farm: params.position.farm,
                nft: params.position.nft,
                tokenId: tokenId
            }),
            params.increase.extraData
        );

        _sweep(sickle, sweepTokens);

        emit SickleRebalancedNft(
            sickle,
            params.position.nft,
            params.position.tokenId,
            params.position.farm.stakingContract,
            params.position.farm.poolIndex
        );
    }

    /* Building blocks */

    function _transferInTokens(
        Sickle sickle,
        NftIncrease calldata params
    ) private {
        bytes4 fee = params.zap.swaps.length > 0
            ? NftFarmStrategyFees.Deposit
            : bytes4(0);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(transferLib);
        data[0] = abi.encodeCall(
            ITransferLib.transferTokensFromUser,
            (params.tokensIn, params.amountsIn, strategyAddress, fee)
        );

        sickle.multicall{ value: msg.value }(targets, data);
    }

    function _transferInNft(
        Sickle sickle,
        INonfungiblePositionManager nft,
        uint256 tokenId
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(nftTransferLib);
        data[0] = abi.encodeCall(
            INftTransferLib.transferErc721FromUser, (nft, tokenId)
        );

        sickle.multicall(targets, data);
    }

    function _transferOutNft(
        Sickle sickle,
        INonfungiblePositionManager nft,
        uint256 tokenId
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(nftTransferLib);
        data[0] =
            abi.encodeCall(INftTransferLib.transferErc721ToUser, (nft, tokenId));

        sickle.multicall(targets, data);
    }

    function _depositNft(
        Sickle sickle,
        NftPosition memory position,
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

    function _withdrawNft(
        Sickle sickle,
        NftPosition calldata position,
        bytes calldata extraData
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        targets[0] = farmConnector;
        data[0] =
            abi.encodeCall(INftFarmConnector.withdrawNft, (position, extraData));

        sickle.multicall(targets, data);

        emit SickleWithdrewNft(
            sickle,
            position.nft,
            position.tokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    // Claim, swap then charge fees on the output
    function _claimAndSwap(
        Sickle sickle,
        NftPosition calldata position,
        NftHarvest calldata params
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            INftFarmConnector.claim,
            (
                position,
                params.harvest.rewardTokens,
                params.harvest.amount0Max,
                params.harvest.amount1Max,
                params.harvest.extraData
            )
        );

        targets[1] = address(swapLib);
        data[1] = abi.encodeCall(ISwapLib.swapMultiple, (params.swaps));

        targets[2] = address(feesLib);
        data[2] = abi.encodeCall(
            IFeesLib.chargeFees,
            (strategyAddress, NftFarmStrategyFees.Harvest, params.outputTokens)
        );
        sickle.multicall(targets, data);
    }

    // Claim then charge fees on the reward tokens
    function _claim(
        Sickle sickle,
        NftPosition calldata position,
        SimpleNftHarvest calldata params,
        bytes4 fee
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            INftFarmConnector.claim,
            (
                position,
                params.rewardTokens,
                params.amount0Max,
                params.amount1Max,
                params.extraData
            )
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            IFeesLib.chargeFees, (strategyAddress, fee, params.rewardTokens)
        );

        sickle.multicall(targets, data);
    }

    function _zapIn(Sickle sickle, NftZapIn calldata zap) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(nftZapLib);
        data[0] = abi.encodeCall(INftZapLib.zapIn, (zap));

        sickle.multicall(targets, data);
    }

    function _zapOut(
        Sickle sickle,
        NftWithdraw calldata params,
        bytes4 withdrawalFee
    ) private {
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = address(nftZapLib);
        data[0] = abi.encodeCall(INftZapLib.zapOut, (params.zap));

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            IFeesLib.chargeFees,
            (strategyAddress, withdrawalFee, params.tokensOut)
        );

        sickle.multicall(targets, data);
    }

    function _setNftSettings(
        Sickle sickle,
        INonfungiblePositionManager nft,
        uint256 tokenId,
        NftSettings calldata settings
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(nftSettingsLib);
        data[0] = abi.encodeCall(
            INftSettingsLib.setNftSettings,
            (nftSettingsRegistry, nft, tokenId, settings)
        );

        sickle.multicall(targets, data);
    }

    function _resetNftSettings(
        Sickle sickle,
        INonfungiblePositionManager nft,
        uint256 tokenId
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(nftSettingsLib);
        data[0] = abi.encodeCall(
            INftSettingsLib.transferNftSettings,
            (nftSettingsRegistry, nft, tokenId)
        );

        sickle.multicall(targets, data);
    }

    function _sweep(Sickle sickle, address[] calldata sweepTokens) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(transferLib);
        data[0] =
            abi.encodeCall(ITransferLib.transferTokensToUser, (sweepTokens));

        sickle.multicall(targets, data);
    }

    function _getRebalanceFee(
        INonfungiblePositionManager nft,
        IUniswapV3Pool pool,
        uint256 tokenId
    ) internal view returns (bytes4) {
        INftLiquidityConnector liquidityConnector =
            INftLiquidityConnector(connectorRegistry.connectorOf(address(nft)));
        uint24 fee = liquidityConnector.fee(address(pool), tokenId);
        if (fee <= REBALANCE_LOW_FEE_BPS) {
            return NftFarmStrategyFees.RebalanceLow;
        } else if (fee <= REBALANCE_MID_FEE_BPS) {
            return NftFarmStrategyFees.RebalanceMid;
        } else {
            return NftFarmStrategyFees.RebalanceHigh;
        }
    }
}
