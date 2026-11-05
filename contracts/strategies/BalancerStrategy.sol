// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    StrategyModule,
    SickleFactory,
    Sickle,
    ConnectorRegistry
} from "contracts/modules/StrategyModule.sol";
import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import {
    Farm,
    HarvestParams,
    WithdrawParams,
    SimpleHarvestParams
} from "contracts/structs/FarmStrategyStructs.sol";
import {
    BalancerPosition,
    BalancerDepositParams,
    BalancerSimpleDepositParams,
    BalancerCompoundParams,
    BalancerMoveParams,
    BalancerPositionOptions
} from "contracts/structs/BalancerStrategyStructs.sol";
import { ZapIn, ZapOut } from "contracts/structs/ZapStructs.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import { ITransferLib } from "contracts/interfaces/libraries/ITransferLib.sol";
import {
    IExactTransferLib
} from "contracts/interfaces/libraries/IExactTransferLib.sol";
import { IZapLib } from "contracts/interfaces/libraries/IZapLib.sol";
import {
    IPositionSettingsLib
} from "contracts/interfaces/libraries/IPositionSettingsLib.sol";
import {
    IPositionSettingsRegistry
} from "contracts/interfaces/IPositionSettingsRegistry.sol";
import {
    PositionKey,
    PositionSettings,
    RewardBehavior
} from "contracts/structs/PositionSettingsStructs.sol";
import {
    BalancerStrategyEvents
} from "contracts/events/BalancerStrategyEvents.sol";

/// @dev The ERC20-farm descriptor names; `SickleRegistry` keys fees per
/// strategy, so they do not alias FarmStrategy's.
library BalancerStrategyFees {
    bytes4 constant Deposit = bytes4(keccak256("FarmDepositFee"));
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
    bytes4 constant Compound = bytes4(keccak256("FarmCompoundFee"));
    bytes4 constant Withdraw = bytes4(keccak256("FarmWithdrawFee"));
    bytes4 constant HarvestFor = bytes4(keccak256("FarmHarvestForFee"));
    bytes4 constant CompoundFor = bytes4(keccak256("FarmCompoundForFee"));
    bytes4 constant Move = bytes4(keccak256("FarmMoveFee"));
}

/// @title BalancerStrategy
/// @notice Sickle strategy for Balancer V3 pools. A position is
/// `(pool, gauge)`: without a gauge the BPT stays in the Sickle, and a gauge
/// is resolved through `ConnectorRegistry` to its `IFarmConnector`. Settings
/// are keyed by the gauge, or by the pool for an unstaked position.
contract BalancerStrategy is StrategyModule, BalancerStrategyEvents {
    struct Libraries {
        ITransferLib transferLib;
        IExactTransferLib exactTransferLib;
        ISwapLib swapLib;
        IFeesLib feesLib;
        IZapLib zapLib;
        IPositionSettingsLib positionSettingsLib;
    }

    error InvalidPool();
    error PoolMismatch();
    error GaugeRequired();
    error RouterMismatch();
    error NothingToWithdraw();
    error InvalidPositionSettings();
    error SamePosition();
    error AutoDepositNotSet();

    /// @notice `lpAmountIn` sentinel: withdraw the whole position.
    uint256 public constant BPT_ALL = type(uint256).max;

    ITransferLib public immutable transferLib;
    IExactTransferLib public immutable exactTransferLib;
    ISwapLib public immutable swapLib;
    IFeesLib public immutable feesLib;
    IZapLib public immutable zapLib;
    IPositionSettingsLib public immutable positionSettingsLib;
    IPositionSettingsRegistry public immutable positionSettingsRegistry;

    address public immutable strategyAddress;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        Libraries memory libraries,
        IPositionSettingsRegistry positionSettingsRegistry_
    ) StrategyModule(factory, connectorRegistry) {
        transferLib = libraries.transferLib;
        exactTransferLib = libraries.exactTransferLib;
        swapLib = libraries.swapLib;
        feesLib = libraries.feesLib;
        zapLib = libraries.zapLib;
        positionSettingsLib = libraries.positionSettingsLib;
        positionSettingsRegistry = positionSettingsRegistry_;
        strategyAddress = address(this);
    }

    modifier onlyApprovedFor(
        Sickle sickle
    ) {
        _requireApproved(sickle);
        _;
    }

    function deposit(
        BalancerDepositParams calldata params,
        PositionSettings calldata positionSettings,
        address[] calldata sweepTokens,
        address approved,
        bytes32 referralCode
    ) external payable {
        _checkSettings(params.position, positionSettings);
        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);
        _increase(sickle, params, sweepTokens);
        _setPositionSettings(sickle, params.position, positionSettings);
        emit BalancerDeposited(
            sickle, params.position.pool, params.position.gauge
        );
    }

    function increase(
        BalancerDepositParams calldata params,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _increase(sickle, params, sweepTokens);
        emit BalancerDeposited(
            sickle, params.position.pool, params.position.gauge
        );
    }

    /// @notice Deposit BPT the owner already holds (no zap, no fee).
    function simpleDeposit(
        BalancerSimpleDepositParams calldata params,
        PositionSettings calldata positionSettings,
        address approved,
        bytes32 referralCode
    ) external {
        _checkSettings(params.position, positionSettings);
        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);
        _simpleIncrease(sickle, params);
        _setPositionSettings(sickle, params.position, positionSettings);
        emit BalancerDeposited(
            sickle, params.position.pool, params.position.gauge
        );
    }

    function simpleIncrease(
        BalancerSimpleDepositParams calldata params
    ) external {
        Sickle sickle = getSickle(msg.sender);
        _simpleIncrease(sickle, params);
        emit BalancerDeposited(
            sickle, params.position.pool, params.position.gauge
        );
    }

    /// @notice `lpAmountIn` may be `BPT_ALL` for the whole position.
    function withdraw(
        BalancerPosition calldata position,
        WithdrawParams calldata params,
        address[] calldata sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);
        bytes4 fee = params.zap.swaps.length > 0
            ? BalancerStrategyFees.Withdraw
            : bytes4(0);
        uint256 bptAmount =
            _withdraw(sickle, position, params, sweepTokens, fee, false);
        emit BalancerWithdrawn(sickle, position.pool, position.gauge, bptAmount);
    }

    /// @notice Harvest (gauged only) and withdraw the whole position.
    function exit(
        BalancerPosition calldata position,
        HarvestParams calldata harvestParams,
        address[] calldata harvestSweepTokens,
        WithdrawParams calldata withdrawParams,
        address[] calldata withdrawSweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);
        uint256 bptAmount = _exit(
            sickle,
            position,
            harvestParams,
            harvestSweepTokens,
            withdrawParams,
            withdrawSweepTokens,
            BalancerStrategyFees.Harvest
        );
        emit BalancerExited(sickle, position.pool, position.gauge, bptAmount);
    }

    /// @notice Send BPT to the owner as-is; `BPT_ALL` for the whole position.
    function simpleWithdraw(
        BalancerPosition calldata position,
        uint256 bptAmount,
        bytes calldata gaugeExtraData
    ) external {
        Sickle sickle = getSickle(msg.sender);
        uint256 amount = _sendBpt(sickle, position, bptAmount, gaugeExtraData);
        emit BalancerWithdrawn(sickle, position.pool, position.gauge, amount);
    }

    /// @notice Harvest (gauged only) and send every BPT to the owner as-is.
    function simpleExit(
        BalancerPosition calldata position,
        SimpleHarvestParams calldata harvestParams,
        bytes calldata gaugeExtraData
    ) external {
        Sickle sickle = getSickle(msg.sender);
        if (position.gauge != address(0)) {
            _simpleHarvest(sickle, position, harvestParams);
        }
        uint256 amount = _sendBpt(sickle, position, BPT_ALL, gaugeExtraData);
        emit BalancerExited(sickle, position.pool, position.gauge, amount);
    }

    /// @notice Move the whole `from` position into `to`. Across pools the
    /// liquidity is exited (move fee) and re-added; within a pool the BPT is
    /// only unstaked and/or restaked, with no fee.
    function move(
        BalancerMoveParams calldata params,
        PositionSettings calldata settings,
        address[] calldata sweepTokens
    ) external {
        if (
            params.from.pool == params.to.pool
                && params.from.gauge == params.to.gauge
        ) revert SamePosition();
        _checkSettings(params.to, settings);
        Sickle sickle = getSickle(msg.sender);

        if (params.from.gauge != address(0)) {
            _harvest(
                sickle,
                params.from,
                params.harvest,
                params.harvestSweepTokens,
                BalancerStrategyFees.Harvest
            );
        }

        if (params.from.pool == params.to.pool) {
            _restake(sickle, params);
        } else {
            _withdraw(
                sickle,
                params.from,
                params.withdraw,
                new address[](0),
                BalancerStrategyFees.Move,
                true
            );
            _zapAndStake(
                sickle,
                params.to,
                params.zap,
                params.gaugeExtraData,
                sweepTokens
            );
        }

        _setPositionSettings(sickle, params.to, settings);
        emit BalancerMoved(
            sickle,
            params.from.pool,
            params.from.gauge,
            params.to.pool,
            params.to.gauge
        );
    }

    function harvest(
        BalancerPosition calldata position,
        HarvestParams calldata params,
        address[] calldata sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);
        _harvest(
            sickle, position, params, sweepTokens, BalancerStrategyFees.Harvest
        );
        emit BalancerHarvested(sickle, position.pool, position.gauge);
    }

    function compound(
        BalancerPosition calldata position,
        BalancerCompoundParams calldata params,
        address[] calldata sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);
        _compound(
            sickle, position, params, sweepTokens, BalancerStrategyFees.Compound
        );
        emit BalancerCompounded(sickle, position.pool, position.gauge);
    }

    function simpleHarvest(
        BalancerPosition calldata position,
        SimpleHarvestParams calldata params
    ) external {
        Sickle sickle = getSickle(msg.sender);
        _simpleHarvest(sickle, position, params);
    }

    function harvestFor(
        Sickle sickle,
        BalancerPosition calldata position,
        HarvestParams calldata params,
        address[] calldata sweepTokens
    ) external onlyApprovedFor(sickle) {
        (PositionKey memory key,) = _keeperKey(sickle, position);
        positionSettingsRegistry.validateHarvestFor(key);
        _harvest(
            sickle,
            position,
            params,
            sweepTokens,
            BalancerStrategyFees.HarvestFor
        );
        emit BalancerHarvested(sickle, position.pool, position.gauge);
    }

    function compoundFor(
        Sickle sickle,
        BalancerPosition calldata position,
        BalancerCompoundParams calldata params,
        address[] calldata sweepTokens
    ) external onlyApprovedFor(sickle) {
        (PositionKey memory key, PositionSettings memory settings) =
            _keeperKey(sickle, position);
        positionSettingsRegistry.validateCompoundFor(key);
        if (params.zap.addLiquidityParams.router != settings.router) {
            revert RouterMismatch();
        }
        _compound(
            sickle,
            position,
            params,
            sweepTokens,
            BalancerStrategyFees.CompoundFor
        );
        emit BalancerCompounded(sickle, position.pool, position.gauge);
    }

    /// @notice Keeper deposit for an owner who opted into `autoDeposit`,
    /// through the owner's recorded router. Empty `tokensIn` uses only tokens
    /// already in the Sickle.
    function depositFor(
        Sickle sickle,
        BalancerDepositParams calldata params,
        address[] calldata sweepTokens
    ) external onlyApprovedFor(sickle) {
        (, PositionSettings memory settings) =
            _keeperKey(sickle, params.position);
        if (!_options(settings.extraData).autoDeposit) {
            revert AutoDepositNotSet();
        }
        if (params.zap.addLiquidityParams.router != settings.router) {
            revert RouterMismatch();
        }
        if (params.tokensIn.length > 0) _pullFromOwner(sickle, params, 0);
        _zapAndStake(
            sickle,
            params.position,
            params.zap,
            params.gaugeExtraData,
            sweepTokens
        );
        emit BalancerDeposited(
            sickle, params.position.pool, params.position.gauge
        );
    }

    /// @notice Keeper exit of the whole position through the owner's recorded
    /// router, once the exit trigger fires.
    function exitFor(
        Sickle sickle,
        BalancerPosition calldata position,
        HarvestParams calldata harvestParams,
        address[] calldata harvestSweepTokens,
        WithdrawParams calldata withdrawParams,
        address[] calldata withdrawSweepTokens
    ) external onlyApprovedFor(sickle) {
        (PositionKey memory key, PositionSettings memory settings) =
            _keeperKey(sickle, position);
        positionSettingsRegistry.validateExitFor(key);
        if (withdrawParams.zap.removeLiquidityParams.router != settings.router)
        {
            revert RouterMismatch();
        }
        uint256 bptAmount = _exit(
            sickle,
            position,
            harvestParams,
            harvestSweepTokens,
            withdrawParams,
            withdrawSweepTokens,
            BalancerStrategyFees.HarvestFor
        );
        emit BalancerExited(sickle, position.pool, position.gauge, bptAmount);
    }

    /// @notice The position's BPT: the Sickle's balance of the pool when
    /// unstaked, the gauge balance when gauged.
    function positionBalance(
        Sickle sickle,
        BalancerPosition calldata position
    ) public view returns (uint256) {
        if (position.gauge == address(0)) {
            return IERC20(position.pool).balanceOf(address(sickle));
        }
        return IFarmConnector(connectorRegistry.connectorOf(position.gauge))
            .balanceOf(_farm(position.gauge), address(sickle));
    }

    function positionKey(
        Sickle sickle,
        BalancerPosition calldata position
    ) external pure returns (PositionKey memory) {
        return _key(sickle, position);
    }

    function _increase(
        Sickle sickle,
        BalancerDepositParams calldata params,
        address[] calldata sweepTokens
    ) private {
        // Transfer first to keep further actions non-payable.
        _pullFromOwner(sickle, params, msg.value);
        _zapAndStake(
            sickle,
            params.position,
            params.zap,
            params.gaugeExtraData,
            sweepTokens
        );
    }

    function _zapAndStake(
        Sickle sickle,
        BalancerPosition calldata position,
        ZapIn calldata zap,
        bytes calldata gaugeExtraData,
        address[] calldata sweepTokens
    ) private {
        if (zap.addLiquidityParams.lpToken != position.pool) {
            revert PoolMismatch();
        }
        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        targets[0] = address(zapLib);
        data[0] = abi.encodeCall(IZapLib.zapIn, (zap));
        if (position.gauge != address(0)) {
            (targets[1], data[1]) = _stakeCall(position, gaugeExtraData);
        }
        if (sweepTokens.length > 0) {
            targets[2] = address(transferLib);
            data[2] = abi.encodeCall(
                ITransferLib.transferTokensToUser, (sweepTokens)
            );
        }
        sickle.multicall(targets, data);
    }

    function _simpleIncrease(
        Sickle sickle,
        BalancerSimpleDepositParams calldata params
    ) private {
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        targets[0] = address(transferLib);
        data[0] = abi.encodeCall(
            ITransferLib.transferTokenFromUser,
            (params.position.pool, params.bptAmount, strategyAddress, bytes4(0))
        );
        if (params.position.gauge != address(0)) {
            (targets[1], data[1]) =
                _stakeCall(params.position, params.gaugeExtraData);
        }
        sickle.multicall(targets, data);
    }

    function _stakeCall(
        BalancerPosition calldata position,
        bytes calldata gaugeExtraData
    ) private view returns (address target, bytes memory data) {
        target = connectorRegistry.connectorOf(position.gauge);
        data = abi.encodeCall(
            IFarmConnector.deposit,
            (_farm(position.gauge), position.pool, gaugeExtraData)
        );
    }

    function _unstakeCall(
        BalancerPosition calldata position,
        uint256 amount,
        bytes calldata gaugeExtraData
    ) private view returns (address target, bytes memory data) {
        target = connectorRegistry.connectorOf(position.gauge);
        data = abi.encodeCall(
            IFarmConnector.withdraw,
            (_farm(position.gauge), amount, gaugeExtraData)
        );
    }

    function _withdraw(
        Sickle sickle,
        BalancerPosition calldata position,
        WithdrawParams calldata params,
        address[] memory sweepTokens,
        bytes4 fee,
        bool full
    ) private returns (uint256 amount) {
        if (params.zap.removeLiquidityParams.lpToken != position.pool) {
            revert PoolMismatch();
        }
        amount = _resolveAmount(
            sickle,
            position,
            full ? BPT_ALL : params.zap.removeLiquidityParams.lpAmountIn
        );

        ZapOut memory zap = params.zap;
        zap.removeLiquidityParams.lpAmountIn = amount;

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        if (position.gauge != address(0)) {
            (targets[0], data[0]) =
                _unstakeCall(position, amount, params.extraData);
        }
        targets[1] = address(zapLib);
        data[1] = abi.encodeCall(IZapLib.zapOut, (zap));
        targets[2] = address(feesLib);
        data[2] = abi.encodeCall(
            IFeesLib.chargeFees, (strategyAddress, fee, params.tokensOut)
        );
        // `move` keeps the proceeds in the Sickle for the next add.
        if (sweepTokens.length > 0) {
            targets[3] = address(transferLib);
            data[3] = abi.encodeCall(
                ITransferLib.transferTokensToUser, (sweepTokens)
            );
        }
        sickle.multicall(targets, data);
    }

    function _resolveAmount(
        Sickle sickle,
        BalancerPosition calldata position,
        uint256 requested
    ) private view returns (uint256 amount) {
        if (position.pool == address(0)) revert InvalidPool();
        amount = requested == BPT_ALL
            ? positionBalance(sickle, position)
            : requested;
        if (amount == 0) revert NothingToWithdraw();
    }

    /// @dev `ExactTransferLib`, not a balance sweep: for an unstaked position
    /// the Sickle's balance is the whole position.
    function _sendBpt(
        Sickle sickle,
        BalancerPosition calldata position,
        uint256 bptAmount,
        bytes calldata gaugeExtraData
    ) private returns (uint256 amount) {
        amount = _resolveAmount(sickle, position, bptAmount);
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        if (position.gauge != address(0)) {
            (targets[0], data[0]) =
                _unstakeCall(position, amount, gaugeExtraData);
        }
        targets[1] = address(exactTransferLib);
        data[1] = abi.encodeCall(
            IExactTransferLib.transferERC20ToUser, (position.pool, amount)
        );
        sickle.multicall(targets, data);
    }

    function _simpleHarvest(
        Sickle sickle,
        BalancerPosition calldata position,
        SimpleHarvestParams calldata params
    ) private {
        _requireGauge(position);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        targets[0] = connectorRegistry.connectorOf(position.gauge);
        data[0] = abi.encodeCall(
            IFarmConnector.claim, (_farm(position.gauge), params.extraData)
        );
        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            IFeesLib.chargeFees,
            (strategyAddress, BalancerStrategyFees.Harvest, params.rewardTokens)
        );
        targets[2] = address(transferLib);
        data[2] = abi.encodeCall(
            ITransferLib.transferTokensToUser, (params.rewardTokens)
        );
        sickle.multicall(targets, data);

        emit BalancerHarvested(sickle, position.pool, position.gauge);
    }

    /// @dev Same-pool move: unstake `from`, then stake the Sickle's balance
    /// into `to.gauge`.
    function _restake(
        Sickle sickle,
        BalancerMoveParams calldata params
    ) private {
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        if (params.from.gauge != address(0)) {
            (targets[0], data[0]) = _unstakeCall(
                params.from,
                positionBalance(sickle, params.from),
                params.withdraw.extraData
            );
        }
        if (params.to.gauge != address(0)) {
            (targets[1], data[1]) = _stakeCall(params.to, params.gaugeExtraData);
        }
        sickle.multicall(targets, data);
    }

    function _exit(
        Sickle sickle,
        BalancerPosition calldata position,
        HarvestParams calldata harvestParams,
        address[] calldata harvestSweepTokens,
        WithdrawParams calldata withdrawParams,
        address[] calldata withdrawSweepTokens,
        bytes4 harvestFee
    ) private returns (uint256) {
        if (position.gauge != address(0)) {
            _harvest(
                sickle, position, harvestParams, harvestSweepTokens, harvestFee
            );
        }
        return _withdraw(
            sickle,
            position,
            withdrawParams,
            withdrawSweepTokens,
            BalancerStrategyFees.Withdraw,
            true
        );
    }

    function _harvest(
        Sickle sickle,
        BalancerPosition calldata position,
        HarvestParams calldata params,
        address[] calldata sweepTokens,
        bytes4 fee
    ) private {
        _requireGauge(position);

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        targets[0] = connectorRegistry.connectorOf(position.gauge);
        data[0] = abi.encodeCall(
            IFarmConnector.claim, (_farm(position.gauge), params.extraData)
        );
        targets[1] = address(swapLib);
        data[1] = abi.encodeCall(ISwapLib.swapMultiple, (params.swaps));
        targets[2] = address(feesLib);
        data[2] = abi.encodeCall(
            IFeesLib.chargeFees, (strategyAddress, fee, params.tokensOut)
        );
        targets[3] = address(transferLib);
        data[3] =
            abi.encodeCall(ITransferLib.transferTokensToUser, (sweepTokens));
        sickle.multicall(targets, data);
    }

    function _compound(
        Sickle sickle,
        BalancerPosition calldata position,
        BalancerCompoundParams calldata params,
        address[] calldata sweepTokens,
        bytes4 fee
    ) private {
        _requireGauge(position);
        if (params.zap.addLiquidityParams.lpToken != position.pool) {
            revert PoolMismatch();
        }

        address[] memory targets = new address[](5);
        bytes[] memory data = new bytes[](5);
        targets[0] = connectorRegistry.connectorOf(position.gauge);
        data[0] = abi.encodeCall(
            IFarmConnector.claim, (_farm(position.gauge), params.claimExtraData)
        );
        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            IFeesLib.chargeFees, (strategyAddress, fee, params.rewardTokens)
        );
        targets[2] = address(zapLib);
        data[2] = abi.encodeCall(IZapLib.zapIn, (params.zap));
        (targets[3], data[3]) = _stakeCall(position, params.gaugeExtraData);
        targets[4] = address(transferLib);
        data[4] =
            abi.encodeCall(ITransferLib.transferTokensToUser, (sweepTokens));
        sickle.multicall(targets, data);
    }

    function _setPositionSettings(
        Sickle sickle,
        BalancerPosition calldata position,
        PositionSettings calldata settings
    ) private {
        _singleMulticall(
            sickle,
            address(positionSettingsLib),
            abi.encodeCall(
                IPositionSettingsLib.setPositionSettings,
                (
                    positionSettingsRegistry,
                    _farm(_stakingContract(position)),
                    settings
                )
            ),
            0
        );
    }

    /// @dev Deposit fee only when the zap swaps.
    function _pullFromOwner(
        Sickle sickle,
        BalancerDepositParams calldata params,
        uint256 value
    ) private {
        _singleMulticall(
            sickle,
            address(transferLib),
            abi.encodeCall(
                ITransferLib.transferTokensFromUser,
                (
                    params.tokensIn,
                    params.amountsIn,
                    strategyAddress,
                    params.zap.swaps.length > 0
                        ? BalancerStrategyFees.Deposit
                        : bytes4(0)
                )
            ),
            value
        );
    }

    function _singleMulticall(
        Sickle sickle,
        address target,
        bytes memory data,
        uint256 value
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory calls = new bytes[](1);
        targets[0] = target;
        calls[0] = data;
        sickle.multicall{ value: value }(targets, calls);
    }

    /// @dev Runs wherever a position is recorded, so recorded pools are
    /// non-zero. Automation must name the position's own pool: exit triggers
    /// are priced off `settings.pool`.
    function _checkSettings(
        BalancerPosition calldata position,
        PositionSettings calldata settings
    ) private pure {
        if (position.pool == address(0)) revert InvalidPool();
        if (settings.automateRewards) _requireGauge(position);
        bool autoDeposit = _options(settings.extraData).autoDeposit;
        if (
            (settings.autoExit || settings.automateRewards || autoDeposit)
                && settings.pool != position.pool
        ) revert InvalidPositionSettings();
        // Every keeper path that adds or removes liquidity is bound to it.
        bool usesRouter = settings.autoExit || autoDeposit
            || (settings.automateRewards
                && settings.rewardConfig.rewardBehavior
                    == RewardBehavior.Compound);
        if (usesRouter && settings.router == address(0)) {
            revert InvalidPositionSettings();
        }
    }

    /// @dev Empty = all off; anything else must be one encoded
    /// `BalancerPositionOptions`.
    function _options(
        bytes memory extraData
    ) private pure returns (BalancerPositionOptions memory options) {
        if (extraData.length == 0) return options;
        if (extraData.length != 32) revert InvalidPositionSettings();
        options = abi.decode(extraData, (BalancerPositionOptions));
    }

    /// @dev A gauged position's key is the gauge alone, so the keeper's
    /// `position.pool` must also match the pool the owner consented for.
    function _keeperKey(
        Sickle sickle,
        BalancerPosition calldata position
    )
        private
        view
        returns (PositionKey memory key, PositionSettings memory settings)
    {
        key = _key(sickle, position);
        settings = positionSettingsRegistry.getPositionSettings(key);
        if (settings.pool != position.pool) revert PoolMismatch();
    }

    function _key(
        Sickle sickle,
        BalancerPosition calldata position
    ) private pure returns (PositionKey memory) {
        return PositionKey({
            sickle: sickle,
            stakingContract: _stakingContract(position),
            poolIndex: 0
        });
    }

    /// @dev `gauge == pool` would pass as a gauge (the pool resolves to this
    /// strategy's own farm connector) while sharing the unstaked key.
    function _stakingContract(
        BalancerPosition calldata position
    ) private pure returns (address) {
        if (position.gauge == position.pool) revert InvalidPool();
        return position.gauge != address(0) ? position.gauge : position.pool;
    }

    function _requireGauge(
        BalancerPosition calldata position
    ) private pure {
        if (position.gauge == address(0) || position.gauge == position.pool) {
            revert GaugeRequired();
        }
    }

    function _farm(
        address stakingContract
    ) private pure returns (Farm memory) {
        return Farm({ stakingContract: stakingContract, poolIndex: 0 });
    }
}
