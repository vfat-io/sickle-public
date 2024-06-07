// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "../Sickle.sol";
import { ConnectorRegistry } from "../ConnectorRegistry.sol";
import {
    TransferModule,
    SickleFactory,
    FeesLib
} from "./modules/TransferModule.sol";
import { IFarmConnector } from "../interfaces/IFarmConnector.sol";

library SimpleFarmStrategyFees {
    bytes4 constant Harvest = bytes4(keccak256("SimpleFarmHarvestFee"));
}

contract SimpleFarmStrategy is TransferModule {
    ConnectorRegistry immutable connectorRegistry;

    constructor(
        SickleFactory factory,
        FeesLib feesLib,
        address wrappedNativeAddress,
        ConnectorRegistry connectorRegistry_
    ) TransferModule(factory, feesLib, wrappedNativeAddress) {
        connectorRegistry = connectorRegistry_;
    }

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

    function deposit(
        DepositParams calldata params,
        address approved,
        bytes32 referralCode
    ) public payable {
        Sickle sickle = Sickle(
            payable(factory.getOrDeploy(msg.sender, approved, referralCode))
        );
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = address(this);
        data[0] = abi.encodeCall(
            this._sickle_transfer_token_from_user,
            (params.lpToken, params.amountIn, address(this), bytes4(0))
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

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_transfer_token_to_user, (params.lpToken)
        );

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

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fees,
            (address(this), SimpleFarmStrategyFees.Harvest, params.tokensOut)
        );

        targets[2] = address(this);
        data[2] = abi.encodeCall(
            this._sickle_transfer_tokens_to_user, (params.tokensOut)
        );

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
