// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { FeesLib } from "contracts/libraries/FeesLib.sol";
import { TransferLib } from "contracts/libraries/TransferLib.sol";
import { ZapLib, ZapInData, ZapOutData } from "contracts/libraries/ZapLib.sol";
import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import {
    StrategyModule,
    Sickle,
    SickleFactory,
    ConnectorRegistry
} from "contracts/modules/StrategyModule.sol";
import { SwapData } from "contracts/interfaces/ILiquidityConnector.sol";

library AerodromeSlipstreamStrategyFees {
    bytes4 constant Deposit = bytes4(keccak256("AerodromeSlipstreamDepositFee"));
    bytes4 constant Harvest = bytes4(keccak256("AerodromeSlipstreamHarvestFee"));
    bytes4 constant Compound =
        bytes4(keccak256("AerodromeSlipstreamCompoundFee"));
    bytes4 constant CompoundFor =
        bytes4(keccak256("AerodromeSlipstreamCompoundForFee"));
    bytes4 constant Withdraw =
        bytes4(keccak256("AerodromeSlipstreamWithdrawFee"));
    bytes4 constant Rebalance =
        bytes4(keccak256("AerodromeSlipstreamRebalanceFee"));
}

contract AerodromeSlipstreamStrategy is StrategyModule {
    error TokenOutRequired();
    error GasCostExceedsEstimate();

    struct DepositParams {
        address stakingContractAddress;
        address[] tokensIn;
        uint256[] amountsIn;
        ZapInData zapData;
        bytes extraData;
    }

    struct WithdrawParams {
        address stakingContractAddress;
        bytes extraData;
        ZapOutData zapData;
        address[] tokensOut;
    }

    struct HarvestParams {
        address stakingContractAddress;
        SwapData[] swaps;
        bytes extraData;
        address[] tokensOut;
    }

    struct CompoundParams {
        address claimContractAddress;
        bytes claimExtraData;
        address[] rewardTokens;
        ZapInData zapData;
        address depositContractAddress;
        bytes depositExtraData;
    }

    struct Libraries {
        ZapLib zapLib;
        TransferLib transferLib;
        FeesLib feesLib;
    }

    ZapLib public immutable zapLib;
    TransferLib public immutable transferLib;
    FeesLib public immutable feesLib;

    address public immutable strategyAddress;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        Libraries memory libraries
    ) StrategyModule(factory, connectorRegistry) {
        zapLib = libraries.zapLib;
        transferLib = libraries.transferLib;
        feesLib = libraries.feesLib;
        strategyAddress = address(this);
    }

    function compound(
        CompoundParams calldata params,
        address[] memory sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](6);
        bytes[] memory data = new bytes[](6);

        targets[0] = connectorRegistry.connectorOf(params.claimContractAddress);
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (params.claimContractAddress, params.claimExtraData)
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                AerodromeSlipstreamStrategyFees.Compound,
                params.rewardTokens
            )
        );

        targets[2] = connectorRegistry.connectorOf(params.claimContractAddress);
        data[2] = abi.encodeCall(
            IFarmConnector.withdraw,
            (params.claimContractAddress, 0, params.claimExtraData)
        );

        targets[3] = address(zapLib);
        data[3] = abi.encodeCall(ZapLib.zapIn, (params.zapData));

        targets[4] =
            connectorRegistry.connectorOf(params.depositContractAddress);
        data[4] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                params.depositContractAddress,
                params.zapData.addLiquidityData.lpToken,
                params.depositExtraData
            )
        );

        if (sweepTokens.length > 0) {
            targets[5] = address(transferLib);
            data[5] =
                abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));
        }
        sickle.multicall(targets, data);
    }

    function compoundFor(
        address sickleAddress,
        CompoundParams calldata params,
        address[] memory sweepTokens
    ) external checkOwnerOrApproved(sickleAddress) {
        Sickle sickle = Sickle(payable(sickleAddress));

        address[] memory targets = new address[](6);
        bytes[] memory data = new bytes[](6);

        targets[0] = connectorRegistry.connectorOf(params.claimContractAddress);
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (params.claimContractAddress, params.claimExtraData)
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                AerodromeSlipstreamStrategyFees.CompoundFor,
                params.rewardTokens
            )
        );

        targets[2] = connectorRegistry.connectorOf(params.claimContractAddress);
        data[2] = abi.encodeCall(
            IFarmConnector.withdraw,
            (params.claimContractAddress, 0, params.claimExtraData)
        );

        targets[3] = address(zapLib);
        data[3] = abi.encodeCall(ZapLib.zapIn, (params.zapData));

        targets[4] =
            connectorRegistry.connectorOf(params.depositContractAddress);
        data[4] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                params.depositContractAddress,
                params.zapData.addLiquidityData.lpToken,
                params.depositExtraData
            )
        );

        if (sweepTokens.length > 0) {
            targets[5] = address(transferLib);
            data[5] =
                abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));
        }

        sickle.multicall(targets, data);
    }

    function increase(
        HarvestParams calldata harvestParams,
        DepositParams calldata depositParams,
        address[] memory sweepTokens
    ) external payable {
        if (depositParams.tokensIn.length == 0) {
            revert TransferLib.TokenInRequired();
        }

        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(transferLib);
        data[0] = abi.encodeCall(
            TransferLib.transferTokensFromUser,
            (
                depositParams.tokensIn,
                depositParams.amountsIn,
                strategyAddress,
                AerodromeSlipstreamStrategyFees.Deposit
            )
        );

        sickle.multicall{ value: msg.value }(targets, data);

        targets = new address[](6);
        data = new bytes[](6);

        targets[0] =
            connectorRegistry.connectorOf(harvestParams.stakingContractAddress);
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (harvestParams.stakingContractAddress, harvestParams.extraData)
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                AerodromeSlipstreamStrategyFees.Harvest,
                harvestParams.tokensOut
            )
        );

        targets[2] =
            connectorRegistry.connectorOf(harvestParams.stakingContractAddress);
        data[2] = abi.encodeCall(
            IFarmConnector.withdraw,
            (harvestParams.stakingContractAddress, 0, harvestParams.extraData)
        );

        targets[3] = address(zapLib);
        data[3] = abi.encodeCall(ZapLib.zapIn, (depositParams.zapData));

        targets[4] =
            connectorRegistry.connectorOf(depositParams.stakingContractAddress);
        data[4] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                depositParams.stakingContractAddress,
                depositParams.zapData.addLiquidityData.lpToken,
                depositParams.extraData
            )
        );

        if (sweepTokens.length > 0) {
            targets[5] = address(transferLib);
            data[5] =
                abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));
        }

        sickle.multicall(targets, data);
    }

    function decrease(
        HarvestParams calldata harvestParams,
        WithdrawParams calldata withdrawParams,
        DepositParams calldata depositParams,
        address[] memory sweepTokens
    ) external {
        if (withdrawParams.tokensOut.length == 0) {
            revert TokenOutRequired();
        }

        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](7);
        bytes[] memory data = new bytes[](7);

        targets[0] =
            connectorRegistry.connectorOf(harvestParams.stakingContractAddress);
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (harvestParams.stakingContractAddress, harvestParams.extraData)
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                AerodromeSlipstreamStrategyFees.Harvest,
                harvestParams.tokensOut
            )
        );

        targets[2] =
            connectorRegistry.connectorOf(withdrawParams.stakingContractAddress);
        data[2] = abi.encodeCall(
            IFarmConnector.withdraw,
            (
                withdrawParams.stakingContractAddress,
                withdrawParams.zapData.removeLiquidityData.lpAmountIn,
                withdrawParams.extraData
            )
        );

        targets[3] = address(zapLib);
        data[3] = abi.encodeCall(ZapLib.zapOut, (withdrawParams.zapData));

        targets[4] =
            connectorRegistry.connectorOf(depositParams.stakingContractAddress);
        data[4] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                depositParams.stakingContractAddress,
                depositParams.zapData.addLiquidityData.lpToken,
                depositParams.extraData
            )
        );

        targets[5] = address(feesLib);
        data[5] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                AerodromeSlipstreamStrategyFees.Withdraw,
                withdrawParams.tokensOut
            )
        );

        if (sweepTokens.length > 0) {
            targets[6] = address(transferLib);
            data[6] =
                abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));
        }

        sickle.multicall(targets, data);
    }
}
