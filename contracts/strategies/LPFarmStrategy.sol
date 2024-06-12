// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    StrategyModule,
    SickleFactory,
    Sickle,
    ConnectorRegistry
} from "contracts/modules/StrategyModule.sol";
import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import { ZapLib, ZapInData, ZapOutData } from "contracts/libraries/ZapLib.sol";
import { FeesLib } from "contracts/libraries/FeesLib.sol";
import { TransferLib } from "contracts/libraries/TransferLib.sol";
import { SwapData } from "contracts/interfaces/ILiquidityConnector.sol";

library LPFarmStrategyFees {
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
}

contract LPFarmStrategy is StrategyModule {
    error SwapsNotAllowed();
    error ArrayLengthMismatch();

    struct Libraries {
        TransferLib transferLib;
        ZapLib zapLib;
        FeesLib feesLib;
    }

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

    function deposit(
        DepositParams calldata params,
        address[] memory sweepTokens,
        address approved,
        bytes32 referralCode
    ) public payable {
        if (params.tokensIn.length != params.amountsIn.length) {
            revert ArrayLengthMismatch();
        }
        if (params.tokensIn.length == 0) {
            revert TransferLib.TokenInRequired();
        }
        if (params.zapData.swaps.length != 0) {
            revert SwapsNotAllowed();
        }

        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);

        targets[0] = address(transferLib);
        data[0] = abi.encodeCall(
            TransferLib.transferTokensFromUser,
            (params.tokensIn, params.amountsIn, strategyAddress, bytes4(0))
        );

        targets[1] = address(zapLib);
        data[1] = abi.encodeCall(ZapLib.zapIn, (params.zapData));

        targets[2] =
            connectorRegistry.connectorOf(params.stakingContractAddress);
        data[2] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                params.stakingContractAddress,
                params.zapData.addLiquidityData.lpToken,
                params.extraData
            )
        );

        if (sweepTokens.length > 0) {
            targets[3] = address(transferLib);
            data[3] =
                abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));
        }

        sickle.multicall{ value: msg.value }(targets, data);
    }

    function withdraw(
        WithdrawParams calldata params,
        address[] memory sweepTokens
    ) public {
        if (params.zapData.swaps.length != 0) {
            revert SwapsNotAllowed();
        }

        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        address farmConnector =
            connectorRegistry.connectorOf(params.stakingContractAddress);
        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.withdraw,
            (
                params.stakingContractAddress,
                params.zapData.removeLiquidityData.lpAmountIn,
                params.extraData
            )
        );

        targets[1] = address(zapLib);
        data[1] = abi.encodeCall(ZapLib.zapOut, (params.zapData));

        targets[2] = address(transferLib);
        data[2] =
            abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));

        sickle.multicall(targets, data);
    }

    function _harvest(HarvestParams calldata harvestParams) internal {
        if (harvestParams.swaps.length != 0) {
            revert SwapsNotAllowed();
        }

        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        address farmConnector =
            connectorRegistry.connectorOf(harvestParams.stakingContractAddress);
        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (harvestParams.stakingContractAddress, harvestParams.extraData)
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                LPFarmStrategyFees.Harvest,
                harvestParams.tokensOut
            )
        );

        sickle.multicall(targets, data);
    }

    function exit(
        HarvestParams calldata harvestParams,
        WithdrawParams calldata withdrawParams,
        address[] memory sweepTokens
    ) external {
        _harvest(harvestParams);
        withdraw(withdrawParams, sweepTokens);
    }
}
