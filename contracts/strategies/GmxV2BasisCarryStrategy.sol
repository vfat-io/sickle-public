// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Sickle } from "contracts/Sickle.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { StrategyModule } from "contracts/modules/StrategyModule.sol";
import { TransferLib } from "contracts/libraries/TransferLib.sol";
import { ZapLib, ZapIn } from "contracts/libraries/ZapLib.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import {
    IBasisCarrySettingsLib
} from "contracts/interfaces/libraries/IBasisCarrySettingsLib.sol";
import {
    BasisCarryFundingLib
} from "contracts/libraries/BasisCarryFundingLib.sol";
import { GmxV2Connector } from "contracts/connectors/gmx/GmxV2Connector.sol";
import {
    IBasisCarrySettingsRegistry
} from "contracts/interfaces/IBasisCarrySettingsRegistry.sol";
import {
    IBasisCarryAutomation
} from "contracts/interfaces/IBasisCarryAutomation.sol";
import {
    GmxV2BasisCarryStrategyEvents
} from "contracts/events/GmxV2BasisCarryStrategyEvents.sol";
import {
    BasisCarrySettings
} from "contracts/structs/BasisCarrySettingsStructs.sol";

library GmxV2BasisCarryFees {
    bytes4 constant Deposit = bytes4(keccak256("BasisCarryDepositFee"));
    bytes4 constant Harvest = bytes4(keccak256("BasisCarryHarvestFee"));
    bytes4 constant HarvestFor = bytes4(keccak256("BasisCarryHarvestForFee"));
    bytes4 constant Compound = bytes4(keccak256("BasisCarryCompoundFee"));
    bytes4 constant CompoundFor = bytes4(keccak256("BasisCarryCompoundForFee"));
}

/// @notice Local GMX V2 short-leg manager for basis-carry portfolios.
///
/// LP positions are intentionally managed outside this strategy through the
/// existing NFT stack on whichever chain they live on. This contract only
/// opens, adjusts, harvests, compounds, and exits the GMX short that exists on
/// this chain. Cross-chain hedge policy is an off-chain automation concern.
contract GmxV2BasisCarryStrategy is
    StrategyModule,
    IBasisCarryAutomation,
    GmxV2BasisCarryStrategyEvents
{
    error AddCollateralTokenMismatch();
    error AddCollateralAmountMismatch();
    error AutomatorRebalanceMustNotMoveCollateral();
    error AutomatorDeleverageMustNotGrowSize();
    error AutomatorDeleverageCollateralAmountZero();
    error CompoundMustNotUseExistingCollateral();
    error CompoundClaimEmpty();
    error ExecutionFeeMismatch(uint256 expected, uint256 received);

    TransferLib public immutable transferLib;
    ZapLib public immutable zapLib;
    IFeesLib public immutable feesLib;
    GmxV2Connector public immutable gmxConnector;
    IBasisCarrySettingsRegistry public immutable settingsRegistry;
    IBasisCarrySettingsLib public immutable basisCarrySettingsLib;
    BasisCarryFundingLib public immutable basisCarryFundingLib;

    address public immutable strategyAddress;

    struct Libraries {
        TransferLib transferLib;
        ZapLib zapLib;
        IFeesLib feesLib;
        GmxV2Connector gmxConnector;
        IBasisCarrySettingsRegistry settingsRegistry;
        IBasisCarrySettingsLib basisCarrySettingsLib;
        BasisCarryFundingLib basisCarryFundingLib;
    }

    /// @param tokensIn Token inputs pulled from the user to the Sickle.
    /// @param amountsIn Amounts for `tokensIn`.
    /// @param collateralZap Optional swap-only zap to prepare GMX collateral.
    /// @param automationSettings Local GMX-leg safety settings to store.
    /// @param gmxOpen GMX V2 market-increase short order.
    struct DepositParams {
        address[] tokensIn;
        uint256[] amountsIn;
        ZapIn collateralZap;
        BasisCarrySettings automationSettings;
        GmxV2Connector.OpenShortParams gmxOpen;
    }

    constructor(
        SickleFactory factory_,
        ConnectorRegistry connectorRegistry_,
        Libraries memory libs
    ) StrategyModule(factory_, connectorRegistry_) {
        transferLib = libs.transferLib;
        zapLib = libs.zapLib;
        feesLib = libs.feesLib;
        gmxConnector = libs.gmxConnector;
        settingsRegistry = libs.settingsRegistry;
        basisCarrySettingsLib = libs.basisCarrySettingsLib;
        basisCarryFundingLib = libs.basisCarryFundingLib;
        strategyAddress = address(this);
    }

    /* Owner */

    function deposit(
        DepositParams calldata params,
        address approved,
        bytes32 referralCode
    ) external payable {
        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);
        _depositOrIncrease(sickle, params);
        emit ShortOpened(
            sickle, params.gmxOpen.market, params.gmxOpen.collateralToken
        );
        emit SettingsUpdated(
            sickle,
            params.automationSettings.market,
            params.automationSettings.collateralToken
        );
    }

    function increase(
        DepositParams calldata params
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _depositOrIncrease(sickle, params);
        emit ShortOpened(
            sickle, params.gmxOpen.market, params.gmxOpen.collateralToken
        );
        emit SettingsUpdated(
            sickle,
            params.automationSettings.market,
            params.automationSettings.collateralToken
        );
    }

    function withdraw(
        address[] calldata sweepTokens,
        GmxV2Connector.CloseShortParams calldata gmxClose
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _sweepAndClose(sickle, sweepTokens, gmxClose);
        emit ShortClosed(sickle, gmxClose.market, gmxClose.collateralToken);
    }

    function harvest(
        address market,
        address token
    ) external {
        Sickle sickle = getSickle(msg.sender);
        _harvest(sickle, market, token, GmxV2BasisCarryFees.Harvest);
        emit FundingHarvested(sickle, market, token);
    }

    function compound(
        GmxV2Connector.OpenShortParams calldata gmxAdd
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _compoundFunding(sickle, gmxAdd, GmxV2BasisCarryFees.Compound);
        emit FundingCompounded(sickle, gmxAdd.market, gmxAdd.collateralToken);
    }

    function cancelOrder(
        bytes32 orderKey
    ) external {
        Sickle sickle = getSickle(msg.sender);
        _cancelOrder(sickle, orderKey);
    }

    function addCollateral(
        address collateralToken,
        uint256 collateralAmount,
        GmxV2Connector.OpenShortParams calldata gmxAdd
    ) external payable {
        if (gmxAdd.collateralToken != collateralToken) {
            revert AddCollateralTokenMismatch();
        }
        if (gmxAdd.collateralAmount != collateralAmount) {
            revert AddCollateralAmountMismatch();
        }
        Sickle sickle = getSickle(msg.sender);

        // Pull collateral in its own multicall with no value attached:
        // TransferLib rejects non-zero msg.value when no input token is ETH,
        // and the GMX keeper fee on the open path must travel as msg.value.
        address[] memory t1 = new address[](1);
        bytes[] memory d1 = new bytes[](1);
        t1[0] = address(transferLib);
        d1[0] = abi.encodeCall(
            TransferLib.transferTokenFromUser,
            (collateralToken, collateralAmount, strategyAddress, bytes4(0))
        );
        sickle.multicall(t1, d1);

        _openShort(sickle, gmxAdd);

        emit ShortOpened(sickle, gmxAdd.market, gmxAdd.collateralToken);
    }

    function removeCollateral(
        GmxV2Connector.CloseShortParams calldata gmxRemove
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _closeShort(sickle, gmxRemove);
        emit ShortClosed(sickle, gmxRemove.market, gmxRemove.collateralToken);
    }

    function growShort(
        GmxV2Connector.OpenShortParams calldata gmxOpen
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _openShort(sickle, gmxOpen);
        emit ShortOpened(sickle, gmxOpen.market, gmxOpen.collateralToken);
    }

    function shrinkShort(
        GmxV2Connector.CloseShortParams calldata gmxClose
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _closeShort(sickle, gmxClose);
        emit ShortClosed(sickle, gmxClose.market, gmxClose.collateralToken);
    }

    /* Automation */

    /// @notice Automator collateral-health action. Collateral must already be
    ///         in the Sickle, for example from a prior bridge/buffer workflow.
    function deleverageFor(
        Sickle sickle,
        GmxV2Connector.OpenShortParams calldata gmxAdd
    ) external payable override onlyApproved(sickle) {
        _requireExecutionFee(gmxAdd.executionFee);
        if (gmxAdd.sizeDeltaUsd != 0) {
            revert AutomatorDeleverageMustNotGrowSize();
        }
        if (gmxAdd.collateralAmount == 0) {
            revert AutomatorDeleverageCollateralAmountZero();
        }
        settingsRegistry.validateDeleverageFor(
            sickle,
            gmxAdd.market,
            gmxAdd.collateralToken,
            gmxAdd.collateralAmount
        );
        _openShort(sickle, gmxAdd);
        emit ShortOpened(sickle, gmxAdd.market, gmxAdd.collateralToken);
    }

    function rebalanceShortFor(
        Sickle sickle,
        bool isGrow,
        GmxV2Connector.OpenShortParams calldata gmxOpen,
        GmxV2Connector.CloseShortParams calldata gmxClose
    ) external payable override onlyApproved(sickle) {
        _requireExecutionFee(
            isGrow ? gmxOpen.executionFee : gmxClose.executionFee
        );
        if (isGrow) {
            if (gmxOpen.collateralAmount != 0) {
                revert AutomatorRebalanceMustNotMoveCollateral();
            }
            settingsRegistry.validateRebalanceFor(
                sickle,
                gmxOpen.market,
                gmxOpen.collateralToken,
                gmxOpen.sizeDeltaUsd
            );
            _openShort(sickle, gmxOpen);
            emit ShortOpened(sickle, gmxOpen.market, gmxOpen.collateralToken);
        } else {
            if (gmxClose.collateralDeltaAmount != 0) {
                revert AutomatorRebalanceMustNotMoveCollateral();
            }
            settingsRegistry.validateRebalanceFor(
                sickle,
                gmxClose.market,
                gmxClose.collateralToken,
                gmxClose.sizeDeltaUsd
            );
            GmxV2Connector.CloseShortParams memory gmxCloseFixed = gmxClose;
            gmxCloseFixed.receiver = sickle.owner();
            _closeShort(sickle, gmxCloseFixed);
            emit ShortClosed(
                sickle, gmxCloseFixed.market, gmxCloseFixed.collateralToken
            );
        }
    }

    function harvestFor(
        Sickle sickle,
        address market,
        address token
    ) external override onlyApproved(sickle) {
        settingsRegistry.validateHarvestFor(sickle, market, token);
        _harvest(sickle, market, token, GmxV2BasisCarryFees.HarvestFor);
        emit FundingHarvested(sickle, market, token);
    }

    /// @notice Claim collateral-token funding to the Sickle and post it back
    ///         to GMX. This compounds the USD-collateralized GMX leg only; it
    ///         does not touch any LP leg on this or another chain. Funding
    ///         accrued in the market long token can be harvested to the wallet
    ///         through `harvestFor`.
    function compoundFor(
        Sickle sickle,
        GmxV2Connector.OpenShortParams calldata gmxAdd
    ) external payable override onlyApproved(sickle) {
        _requireExecutionFee(gmxAdd.executionFee);
        settingsRegistry.validateCompoundFor(
            sickle, gmxAdd.market, gmxAdd.collateralToken, gmxAdd.sizeDeltaUsd
        );
        _compoundFunding(sickle, gmxAdd, GmxV2BasisCarryFees.CompoundFor);
        emit FundingCompounded(sickle, gmxAdd.market, gmxAdd.collateralToken);
    }

    function exitFor(
        Sickle sickle,
        address[] calldata sweepTokens,
        GmxV2Connector.CloseShortParams calldata gmxClose
    ) external payable override onlyApproved(sickle) {
        _requireExecutionFee(gmxClose.executionFee);
        // This submits a full close from the current GMX datastore state. The
        // off-chain keeper must not call it while another order for this
        // Sickle/market is still pending in GMX's OrderStore.
        settingsRegistry.validateExitFor(
            sickle, gmxClose.market, gmxClose.collateralToken
        );

        (uint256 sizeInUsd, uint256 collateralAmount) = settingsRegistry.currentShortPosition(
            sickle, gmxClose.market, gmxClose.collateralToken
        );

        GmxV2Connector.CloseShortParams memory gmxCloseFull = gmxClose;
        gmxCloseFull.sizeDeltaUsd = sizeInUsd;
        gmxCloseFull.collateralDeltaAmount = collateralAmount;
        // For closing shorts GMX executes when executablePrice is at or below
        // acceptablePrice. Max keeps the kill-switch fillable instead of
        // letting automators accidentally set a stale or impossible bound.
        gmxCloseFull.acceptablePrice = type(uint256).max;
        gmxCloseFull.callbackContract = address(0);
        gmxCloseFull.callbackGasLimit = 0;
        gmxCloseFull.receiver = sickle.owner();

        _sweepAndClose(sickle, sweepTokens, gmxCloseFull);
        emit ShortClosed(
            sickle, gmxCloseFull.market, gmxCloseFull.collateralToken
        );
    }

    function cancelOrderFor(
        Sickle sickle,
        bytes32 orderKey
    ) external override onlyApproved(sickle) {
        settingsRegistry.validateCancelOrderFor(sickle);
        _cancelOrder(sickle, orderKey);
    }

    /* Private */

    /// @dev Two sickle.multicalls. The first bundles transferIn (with Deposit
    ///      fee gated on the zap), zapIn (no-op when collateralZap is empty),
    ///      and setBasisCarrySettings — all non-payable internals, so the
    ///      multicall carries no msg.value. The second carries msg.value to
    ///      openShort for the GMX keeper execution fee. msg.value cannot be
    ///      forwarded through the first multicall because TransferLib's
    ///      transferTokensFromUser and the swap connectors invoked by ZapLib
    ///      revert on a non-zero value when the input/output is not ETH.
    function _depositOrIncrease(
        Sickle sickle,
        DepositParams calldata params
    ) private {
        bool hasZap = params.collateralZap.swaps.length > 0
            || params.collateralZap.addLiquidityParams.router != address(0);
        bytes4 fee = hasZap ? GmxV2BasisCarryFees.Deposit : bytes4(0);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        if (params.tokensIn.length != 0) {
            targets[0] = address(transferLib);
            data[0] = abi.encodeCall(
                TransferLib.transferTokensFromUser,
                (params.tokensIn, params.amountsIn, strategyAddress, fee)
            );
        }

        if (hasZap) {
            targets[1] = address(zapLib);
            data[1] = abi.encodeCall(ZapLib.zapIn, (params.collateralZap));
        }

        targets[2] = address(basisCarrySettingsLib);
        data[2] = abi.encodeCall(
            basisCarrySettingsLib.setBasisCarrySettings,
            (settingsRegistry, params.automationSettings)
        );

        sickle.multicall(targets, data);

        _openShort(sickle, params.gmxOpen);
    }

    function _sweepAndClose(
        Sickle sickle,
        address[] calldata sweepTokens,
        GmxV2Connector.CloseShortParams memory gmxClose
    ) private {
        if (sweepTokens.length == 0) {
            _closeShort(sickle, gmxClose);
            return;
        }

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        targets[0] = address(gmxConnector);
        data[0] = abi.encodeCall(GmxV2Connector.closeShort, (gmxClose));
        targets[1] = address(transferLib);
        data[1] =
            abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));
        sickle.multicall{ value: msg.value }(targets, data);
    }

    /// @dev Charges the configured fee on the *actual* claimed delta and
    ///      flushes the post-fee remainder to the Sickle owner via the
    ///      basis-carry funding lib. Any pre-existing collateral-token
    ///      buffer in the Sickle (e.g. pre-funded for a future
    ///      `deleverageFor`) is preserved — the lib reads the on-chain
    ///      balance delta inside the same multicall, so claim + fee +
    ///      flush all see consistent state.
    function _harvest(
        Sickle sickle,
        address market,
        address token,
        bytes4 fee
    ) private {
        address[] memory markets = new address[](1);
        markets[0] = market;
        address[] memory tokens = new address[](1);
        tokens[0] = token;

        uint256 balanceBefore = IERC20(token).balanceOf(address(sickle));

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        targets[0] = address(gmxConnector);
        data[0] = abi.encodeCall(GmxV2Connector.claimFunding, (markets, tokens));
        targets[1] = address(basisCarryFundingLib);
        data[1] = abi.encodeCall(
            BasisCarryFundingLib.chargeAndFlush,
            (
                feesLib,
                strategyAddress,
                fee,
                token,
                balanceBefore,
                sickle.owner()
            )
        );
        sickle.multicall(targets, data);
    }

    /// @dev Single multicall: claim funding, then the basis-carry funding lib
    ///      reads the on-chain claimed delta, charges the configured fee on
    ///      that delta only, and reopens the short with `collateralAmount =
    ///      delta - fee`. Pre-existing collateral-token buffer in the Sickle
    ///      (e.g. pre-funded for a future `deleverageFor`) stays untouched.
    ///      msg.value flows through to the inner openShort for the GMX keeper
    ///      fee. CompoundClaimEmpty is raised inside the lib when delta is
    ///      zero, matching the previous strategy-level guard.
    function _compoundFunding(
        Sickle sickle,
        GmxV2Connector.OpenShortParams calldata gmxAdd,
        bytes4 fee
    ) private {
        if (gmxAdd.collateralAmount != 0) {
            revert CompoundMustNotUseExistingCollateral();
        }

        uint256 balanceBefore =
            IERC20(gmxAdd.collateralToken).balanceOf(address(sickle));

        address[] memory markets = new address[](1);
        markets[0] = gmxAdd.market;
        address[] memory tokens = new address[](1);
        tokens[0] = gmxAdd.collateralToken;

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        targets[0] = address(gmxConnector);
        data[0] = abi.encodeCall(GmxV2Connector.claimFunding, (markets, tokens));
        targets[1] = address(basisCarryFundingLib);
        data[1] = abi.encodeCall(
            BasisCarryFundingLib.chargeAndOpenShort,
            (feesLib, gmxConnector, strategyAddress, fee, balanceBefore, gmxAdd)
        );
        sickle.multicall{ value: msg.value }(targets, data);
    }

    function _openShort(
        Sickle sickle,
        GmxV2Connector.OpenShortParams memory gmxOpen
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(gmxConnector);
        data[0] = abi.encodeCall(GmxV2Connector.openShort, (gmxOpen));
        sickle.multicall{ value: msg.value }(targets, data);
    }

    function _closeShort(
        Sickle sickle,
        GmxV2Connector.CloseShortParams memory gmxClose
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(gmxConnector);
        data[0] = abi.encodeCall(GmxV2Connector.closeShort, (gmxClose));
        sickle.multicall{ value: msg.value }(targets, data);
    }

    function _cancelOrder(
        Sickle sickle,
        bytes32 orderKey
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(gmxConnector);
        data[0] = abi.encodeCall(GmxV2Connector.cancelOrder, (orderKey));
        sickle.multicall(targets, data);
    }

    function _requireExecutionFee(
        uint256 expected
    ) private view {
        if (msg.value != expected) {
            revert ExecutionFeeMismatch(expected, msg.value);
        }
    }
}
