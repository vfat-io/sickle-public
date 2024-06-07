// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../Sickle.sol";
import "./modules/TransferModule.sol";
import "./modules/ZapModule.sol";
import "../interfaces/IFarmConnector.sol";

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

contract AerodromeSlipstreamStrategy is ZapModule {
    error TokenOutRequired();
    error GasCostExceedsEstimate();

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

        address[] memory targets = new address[](6);
        bytes[] memory data = new bytes[](6);

        targets[0] = connectorRegistry.connectorOf(params.claimContractAddress);
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (params.claimContractAddress, params.claimExtraData)
        );

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fees,
            (
                address(this),
                AerodromeSlipstreamStrategyFees.Compound,
                params.rewardTokens
            )
        );

        targets[2] = connectorRegistry.connectorOf(params.claimContractAddress);
        data[2] = abi.encodeCall(
            IFarmConnector.withdraw,
            (params.claimContractAddress, 0, params.claimExtraData)
        );

        targets[3] = address(this);
        data[3] = abi.encodeCall(ZapModule._sickle_zap_in, (params.zapData));

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

        targets[5] = address(this);
        data[5] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

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

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fees,
            (
                address(this),
                AerodromeSlipstreamStrategyFees.CompoundFor,
                params.rewardTokens
            )
        );

        targets[2] = connectorRegistry.connectorOf(params.claimContractAddress);
        data[2] = abi.encodeCall(
            IFarmConnector.withdraw,
            (params.claimContractAddress, 0, params.claimExtraData)
        );

        targets[3] = address(this);
        data[3] = abi.encodeCall(ZapModule._sickle_zap_in, (params.zapData));

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

        targets[5] = address(this);
        data[5] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }

    function increase(
        HarvestParams calldata harvestParams,
        DepositParams calldata depositParams,
        address[] memory sweepTokens
    ) external payable {
        if (depositParams.tokensIn.length == 0) {
            revert TokenInRequired();
        }

        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(this);
        data[0] = abi.encodeCall(
            this._sickle_transfer_tokens_from_user,
            (
                depositParams.tokensIn,
                depositParams.amountsIn,
                address(this),
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

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fees,
            (
                address(this),
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

        targets[3] = address(this);
        data[3] =
            abi.encodeCall(ZapModule._sickle_zap_in, (depositParams.zapData));

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

        targets[5] = address(this);
        data[5] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

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

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fees,
            (
                address(this),
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

        targets[3] = address(this);
        data[3] =
            abi.encodeCall(ZapModule._sickle_zap_out, (withdrawParams.zapData));

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

        targets[5] = address(this);
        data[5] = abi.encodeCall(
            this._sickle_charge_fees,
            (
                address(this),
                AerodromeSlipstreamStrategyFees.Withdraw,
                withdrawParams.tokensOut
            )
        );

        targets[6] = address(this);
        data[6] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }
}
