// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../Sickle.sol";
import "./modules/TransferModule.sol";
import "./modules/ZapModule.sol";
import "../interfaces/IFarmConnector.sol";

library FarmStrategyFees {
    bytes4 constant Deposit = bytes4(keccak256("FarmDepositFee"));
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
    bytes4 constant Compound = bytes4(keccak256("FarmCompoundFee"));
    bytes4 constant CompoundFor = bytes4(keccak256("FarmCompoundForFee"));
    bytes4 constant Withdraw = bytes4(keccak256("FarmWithdrawFee"));
    bytes4 constant Rebalance = bytes4(keccak256("FarmRebalanceFee"));
}

contract FarmStrategy is TransferModule, ZapModule {
    error TokenOutRequired();

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
            (
                params.tokensIn,
                params.amountsIn,
                address(this),
                FarmStrategyFees.Deposit
            )
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

    struct CompoundParams {
        address claimContractAddress;
        bytes claimExtraData;
        address[] rewardTokens;
        ZapModule.ZapInData zapData;
        address depositContractAddress;
        bytes depositExtraData;
    }

    function compound(
        CompoundParams calldata params,
        address[] memory sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](5);
        bytes[] memory data = new bytes[](5);

        address farmConnector =
            connectorRegistry.connectorOf(params.claimContractAddress);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (params.claimContractAddress, params.claimExtraData)
        );

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fees,
            (address(this), FarmStrategyFees.Compound, params.rewardTokens)
        );

        targets[2] = address(this);
        data[2] = abi.encodeCall(ZapModule._sickle_zap_in, (params.zapData));

        targets[3] = farmConnector;
        data[3] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                params.depositContractAddress,
                params.zapData.addLiquidityData.lpToken,
                params.depositExtraData
            )
        );

        targets[4] = address(this);
        data[4] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }

    function compoundFor(
        address sickleAddress,
        CompoundParams calldata params,
        address[] memory sweepTokens
    ) external checkOwnerOrApproved(sickleAddress) {
        Sickle sickle = Sickle(payable(sickleAddress));

        address[] memory targets = new address[](5);
        bytes[] memory data = new bytes[](5);

        address farmConnector =
            connectorRegistry.connectorOf(params.claimContractAddress);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (params.claimContractAddress, params.claimExtraData)
        );

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fees,
            (address(this), FarmStrategyFees.CompoundFor, params.rewardTokens)
        );

        targets[2] = address(this);
        data[2] = abi.encodeCall(ZapModule._sickle_zap_in, (params.zapData));

        targets[3] = farmConnector;
        data[3] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                params.depositContractAddress,
                params.zapData.addLiquidityData.lpToken,
                params.depositExtraData
            )
        );

        targets[4] = address(this);
        data[4] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }

    struct WithdrawParams {
        address stakingContractAddress;
        bytes extraData;
        ZapModule.ZapOutData zapData;
        address[] tokensOut;
    }

    function withdraw(
        WithdrawParams calldata params,
        address[] memory sweepTokens
    ) public {
        if (params.tokensOut.length == 0) {
            revert TokenOutRequired();
        }

        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);

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
        data[2] = abi.encodeCall(
            this._sickle_charge_fees,
            (address(this), FarmStrategyFees.Withdraw, params.tokensOut)
        );

        targets[3] = address(this);
        data[3] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }

    struct HarvestParams {
        address stakingContractAddress;
        SwapData[] swaps;
        bytes extraData;
        address[] tokensOut;
    }

    function harvest(
        HarvestParams calldata params,
        address[] memory sweepTokens
    ) public {
        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);

        address farmConnector =
            connectorRegistry.connectorOf(params.stakingContractAddress);
        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (params.stakingContractAddress, params.extraData)
        );

        targets[1] = address(this);
        data[1] =
            abi.encodeCall(SwapModule._sickle_swap_multiple, (params.swaps));
        targets[2] = address(this);
        data[2] = abi.encodeCall(
            this._sickle_charge_fees,
            (address(this), FarmStrategyFees.Harvest, params.tokensOut)
        );

        targets[3] = address(this);
        data[3] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }

    function exit(
        HarvestParams calldata harvestParams,
        WithdrawParams calldata withdrawParams,
        address[] memory sweepTokens
    ) external {
        // Sweep is handled by the withdraw
        harvest(harvestParams, new address[](0));
        withdraw(withdrawParams, sweepTokens);
    }

    function rebalance(
        HarvestParams calldata harvestParams,
        WithdrawParams calldata withdrawParams,
        DepositParams calldata depositParams,
        address[] memory sweepTokens
    ) external {
        if (withdrawParams.tokensOut.length == 0) {
            revert TokenOutRequired();
        }

        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](8);
        bytes[] memory data = new bytes[](8);

        targets[0] =
            connectorRegistry.connectorOf(harvestParams.stakingContractAddress);
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (harvestParams.stakingContractAddress, harvestParams.extraData)
        );

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fees,
            (address(this), FarmStrategyFees.Harvest, harvestParams.tokensOut)
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

        targets[3] = address(this);
        data[3] =
            abi.encodeCall(ZapModule._sickle_zap_out, (withdrawParams.zapData));

        targets[4] = address(this);
        data[4] = abi.encodeCall(
            this._sickle_charge_fees,
            (
                address(this),
                FarmStrategyFees.Rebalance,
                withdrawParams.tokensOut
            )
        );

        targets[5] = address(this);
        data[5] =
            abi.encodeCall(ZapModule._sickle_zap_in, (depositParams.zapData));

        targets[6] =
            connectorRegistry.connectorOf(depositParams.stakingContractAddress);
        data[6] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                depositParams.stakingContractAddress,
                depositParams.zapData.addLiquidityData.lpToken,
                depositParams.extraData
            )
        );

        targets[7] = address(this);
        data[7] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }
}
