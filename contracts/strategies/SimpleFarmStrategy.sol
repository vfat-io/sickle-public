// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { TransferLib, FeesLib } from "contracts/libraries/TransferLib.sol";
import {
    StrategyModule, SickleFactory
} from "contracts/modules/StrategyModule.sol";
import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";

library SimpleFarmStrategyFees {
    bytes4 constant Harvest = bytes4(keccak256("SimpleFarmHarvestFee"));
}

contract SimpleFarmStrategy is StrategyModule {
    struct DepositParams {
        address lpToken;
        uint256 amountIn;
        address stakingContractAddress;
        bytes extraData;
    }

    struct WithdrawParams {
        address lpToken;
        uint256 amountOut;
        address stakingContractAddress;
        bytes extraData;
    }

    struct HarvestParams {
        address[] tokensOut;
        address stakingContractAddress;
        bytes extraData;
    }

    TransferLib public immutable transferLib;
    FeesLib public immutable feesLib;

    address public immutable strategyAddress;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        TransferLib transferLib_,
        FeesLib feesLib_
    ) StrategyModule(factory, connectorRegistry) {
        transferLib = transferLib_;
        feesLib = feesLib_;
        strategyAddress = address(this);
    }

    function deposit(
        DepositParams calldata params,
        address approved,
        bytes32 referralCode
    ) public payable {
        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = address(transferLib);
        data[0] = abi.encodeCall(
            TransferLib.transferTokenFromUser,
            (params.lpToken, params.amountIn, strategyAddress, bytes4(0))
        );

        targets[1] =
            connectorRegistry.connectorOf(params.stakingContractAddress);
        data[1] = abi.encodeCall(
            IFarmConnector.deposit,
            (params.stakingContractAddress, params.lpToken, params.extraData)
        );

        sickle.multicall{ value: msg.value }(targets, data);
    }

    function withdraw(WithdrawParams calldata params) public {
        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        address farmConnector =
            connectorRegistry.connectorOf(params.stakingContractAddress);
        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.withdraw,
            (params.stakingContractAddress, params.amountOut, params.extraData)
        );

        targets[1] = address(transferLib);
        data[1] =
            abi.encodeCall(TransferLib.transferTokenToUser, (params.lpToken));

        sickle.multicall(targets, data);
    }

    function harvest(HarvestParams calldata params) public {
        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        address farmConnector =
            connectorRegistry.connectorOf(params.stakingContractAddress);
        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (params.stakingContractAddress, params.extraData)
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            FeesLib.chargeFees,
            (strategyAddress, SimpleFarmStrategyFees.Harvest, params.tokensOut)
        );

        targets[2] = address(transferLib);
        data[2] =
            abi.encodeCall(TransferLib.transferTokensToUser, (params.tokensOut));

        sickle.multicall(targets, data);
    }

    function exit(
        HarvestParams calldata harvestParams,
        WithdrawParams calldata withdrawParams
    ) external {
        harvest(harvestParams);
        withdraw(withdrawParams);
    }
}
