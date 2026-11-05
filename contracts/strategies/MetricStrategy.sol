// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    StrategyModule,
    SickleFactory,
    Sickle,
    ConnectorRegistry
} from "contracts/modules/StrategyModule.sol";
import { ITransferLib } from "contracts/interfaces/libraries/ITransferLib.sol";
import { TransferLib } from "contracts/libraries/TransferLib.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import {
    IMetricLiquidityConnector
} from "contracts/interfaces/IMetricLiquidityConnector.sol";
import {
    IMetricOmmFactory,
    MetricPoolImmutables
} from "contracts/interfaces/external/metric/IMetricOmm.sol";
import {
    MetricIncrease,
    MetricWithdraw,
    MetricOutput
} from "contracts/structs/MetricStrategyStructs.sol";

library MetricStrategyFees {
    bytes4 constant Deposit = bytes4(keccak256("FarmDepositFee"));
    bytes4 constant Withdraw = bytes4(keccak256("FarmWithdrawFee"));
}

/// @notice Metric liquidity operations for Sickle owners.
contract MetricStrategy is StrategyModule {
    address private constant NATIVE =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    error InvalidDependency();
    error InvalidParameters();
    error InvalidOutput();
    error InsufficientOutput(address token, uint256 received, uint256 minimum);
    error ExistingBalanceConsumed(address token);
    error FullWithdrawalRequired();

    struct Libraries {
        ITransferLib transferLib;
        ISwapLib swapLib;
        IFeesLib feesLib;
    }

    IMetricOmmFactory public immutable metricFactory;
    ITransferLib public immutable transferLib;
    ISwapLib public immutable swapLib;
    IFeesLib public immutable feesLib;

    constructor(
        SickleFactory factory_,
        ConnectorRegistry registry_,
        IMetricOmmFactory metricFactory_,
        Libraries memory libraries
    ) StrategyModule(factory_, registry_) {
        if (
            address(metricFactory_).code.length == 0
                || address(libraries.transferLib).code.length == 0
                || address(libraries.swapLib).code.length == 0
                || address(libraries.feesLib).code.length == 0
        ) {
            revert InvalidDependency();
        }
        metricFactory = metricFactory_;
        transferLib = libraries.transferLib;
        swapLib = libraries.swapLib;
        feesLib = libraries.feesLib;
    }

    function deposit(
        MetricIncrease calldata params,
        address approved,
        bytes32 referralCode
    ) external payable {
        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);
        _increase(sickle, params);
    }

    function increase(
        MetricIncrease calldata params
    ) external payable {
        _increase(getSickle(msg.sender), params);
    }

    function withdraw(
        MetricWithdraw calldata params
    ) external {
        _withdraw(getSickle(msg.sender), params);
    }

    /// @notice Withdraw all shares in the supplied bins for the selected salt.
    /// @dev Supply every held bin to close the position.
    function exit(
        MetricWithdraw calldata params
    ) external {
        for (uint256 i; i < params.liquidity.deltas.shares.length; ++i) {
            if (params.liquidity.deltas.shares[i] != type(uint256).max) {
                revert FullWithdrawalRequired();
            }
        }
        _withdraw(getSickle(msg.sender), params);
    }

    function _increase(
        Sickle sickle,
        MetricIncrease calldata params
    ) private {
        (address connector, MetricPoolImmutables memory info) =
            _connector(params.liquidity.position.pool);
        if (params.tokensIn.length != params.amountsIn.length) {
            revert InvalidParameters();
        }
        if (params.tokensIn.length != 0) {
            _call(
                sickle,
                address(transferLib),
                abi.encodeCall(
                    ITransferLib.transferTokensFromUser,
                    (
                        params.tokensIn,
                        params.amountsIn,
                        address(this),
                        params.swaps.length == 0
                            ? bytes4(0)
                            : MetricStrategyFees.Deposit
                    )
                ),
                msg.value
            );
        } else if (msg.value != 0) {
            revert InvalidParameters();
        }
        for (uint256 i; i < params.swaps.length; ++i) {
            _call(
                sickle,
                address(swapLib),
                abi.encodeCall(ISwapLib.swap, params.swaps[i]),
                0
            );
        }
        _call(
            sickle,
            connector,
            abi.encodeCall(
                IMetricLiquidityConnector.addLiquidity, params.liquidity
            ),
            0
        );
        _sweep(sickle, params.sweepTokens);
        _sweepPoolTokens(sickle, info);
    }

    function _withdraw(
        Sickle sickle,
        MetricWithdraw calldata params
    ) private {
        (address connector, MetricPoolImmutables memory info) =
            _connector(params.liquidity.position.pool);
        uint256[] memory beforeBalances = _snapshot(sickle, params.outputs);
        uint256 before0 = IERC20(info.token0).balanceOf(address(sickle));
        uint256 before1 = IERC20(info.token1).balanceOf(address(sickle));
        _call(
            sickle,
            connector,
            abi.encodeCall(
                IMetricLiquidityConnector.removeLiquidity, params.liquidity
            ),
            0
        );
        if (params.swaps.length != 0) {
            _withdrawFee(sickle, info.token0, before0);
            _withdrawFee(sickle, info.token1, before1);
        }
        for (uint256 i; i < params.swaps.length; ++i) {
            _call(
                sickle,
                address(swapLib),
                abi.encodeCall(ISwapLib.swap, params.swaps[i]),
                0
            );
        }
        for (uint256 i; i < params.outputs.length; ++i) {
            address token = params.outputs[i].token;
            uint256 afterBalance = _outputBalance(sickle, token);
            if (afterBalance < beforeBalances[i]) {
                revert ExistingBalanceConsumed(token);
            }
            uint256 received = afterBalance - beforeBalances[i];
            if (received < params.outputs[i].minAmount) {
                revert InsufficientOutput(
                    token, received, params.outputs[i].minAmount
                );
            }
        }
        for (uint256 i; i < params.outputs.length; ++i) {
            _call(
                sickle,
                address(transferLib),
                abi.encodeCall(
                    ITransferLib.transferTokenToUser, params.outputs[i].token
                ),
                0
            );
        }
        _sweep(sickle, params.sweepTokens);
        _sweepPoolTokens(sickle, info);
    }

    function _withdrawFee(
        Sickle sickle,
        address token,
        uint256 beforeBalance
    ) private {
        uint256 received =
            IERC20(token).balanceOf(address(sickle)) - beforeBalance;
        if (received == 0) return;
        _call(
            sickle,
            address(feesLib),
            abi.encodeCall(
                IFeesLib.chargeFee,
                (address(this), MetricStrategyFees.Withdraw, token, received)
            ),
            0
        );
    }

    function _connector(
        address pool
    )
        private
        view
        returns (address connector, MetricPoolImmutables memory info)
    {
        connector = connectorRegistry.connectorOf(address(metricFactory));
        IMetricLiquidityConnector metric = IMetricLiquidityConnector(connector);
        if (address(metric.metricFactory()) != address(metricFactory)) {
            revert InvalidDependency();
        }
        info = metric.poolInfo(pool);
    }

    function _snapshot(
        Sickle sickle,
        MetricOutput[] calldata outputs
    ) private view returns (uint256[] memory balances) {
        if (outputs.length == 0) revert InvalidOutput();
        balances = new uint256[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            address token = outputs[i].token;
            address asset = _outputAsset(token);
            for (uint256 j; j < i; ++j) {
                if (_outputAsset(outputs[j].token) == asset) {
                    revert InvalidOutput();
                }
            }
            balances[i] = _outputBalance(sickle, token);
        }
    }

    function _outputBalance(
        Sickle sickle,
        address token
    ) private view returns (uint256) {
        uint256 balance = IERC20(_outputAsset(token)).balanceOf(address(sickle));
        return token == address(0) || token == NATIVE
            ? balance + address(sickle).balance
            : balance;
    }

    function _outputAsset(
        address token
    ) private view returns (address) {
        return token == address(0) || token == NATIVE
            ? address(TransferLib(address(transferLib)).weth())
            : token;
    }

    function _sweep(
        Sickle sickle,
        address[] calldata tokens
    ) private {
        if (tokens.length != 0) {
            _call(
                sickle,
                address(transferLib),
                abi.encodeCall(ITransferLib.transferTokensToUser, tokens),
                0
            );
        }
    }

    function _sweepPoolTokens(
        Sickle sickle,
        MetricPoolImmutables memory info
    ) private {
        _call(
            sickle,
            address(transferLib),
            abi.encodeCall(ITransferLib.transferTokenToUser, info.token0),
            0
        );
        _call(
            sickle,
            address(transferLib),
            abi.encodeCall(ITransferLib.transferTokenToUser, info.token1),
            0
        );
    }

    function _call(
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
}
