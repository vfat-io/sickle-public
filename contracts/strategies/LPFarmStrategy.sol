// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../Sickle.sol";
import "./modules/TransferModule.sol";
import "./modules/ZapModule.sol";
import "../interfaces/IFarmConnector.sol";

library LPFarmStrategyFees {
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
}

contract LPFarmStrategy is TransferModule, ZapModule {
    error SwapsNotAllowed();

    constructor(
        SickleFactory factory,
        FeesLib feesLib,
        address wrappedNativeAddress,
        ConnectorRegistry connectorRegistry
    ) ZapModule(factory, feesLib, wrappedNativeAddress, connectorRegistry) { }

    struct DepositParams {
        address stakingContractAddress;
        address[] tokensIn;
        uint256[] amountsIn;
        ZapModule.ZapInData zapData;
        bytes extraData;
    }

    struct WithdrawParams {
        address stakingContractAddress;
        bytes extraData;
        ZapModule.ZapOutData zapData;
        address[] tokensOut;
    }

    struct HarvestParams {
        address stakingContractAddress;
        SwapData[] swaps;
        bytes extraData;
        address[] tokensOut;
    }

    function deposit(
        DepositParams calldata params,
        address[] memory sweepTokens,
        address approved,
        bytes32 referralCode
    ) public payable {
        if (params.tokensIn.length != params.amountsIn.length) {
            revert SickleRegistry.ArrayLengthMismatch();
        }
        if (params.tokensIn.length == 0) {
            revert TokenInRequired();
        }
        Sickle sickle = Sickle(
            payable(factory.getOrDeploy(msg.sender, approved, referralCode))
        );

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);

        targets[0] = address(this);
        data[0] = abi.encodeCall(
            this._sickle_transfer_tokens_from_user,
            (params.tokensIn, params.amountsIn, address(this), bytes4(0))
        );

        targets[1] = address(this);
        data[1] = abi.encodeCall(ZapModule._sickle_zap_in, (params.zapData));

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

        targets[3] = address(this);
        data[3] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

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

        targets[1] = address(this);
        data[1] = abi.encodeCall(ZapModule._sickle_zap_out, (params.zapData));

        targets[2] = address(this);
        data[2] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

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

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fees,
            (address(this), LPFarmStrategyFees.Harvest, harvestParams.tokensOut)
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
