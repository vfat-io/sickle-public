// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../Sickle.sol";
import "./modules/TransferModule.sol";
import "./modules/ZapModule.sol";
import "../interfaces/IFarmConnector.sol";

library MultiFarmStrategyFees {
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
    bytes4 constant Compound = bytes4(keccak256("FarmCompoundFee"));
}

contract MultiFarmStrategy is TransferModule, ZapModule {
    constructor(
        SickleFactory factory,
        FeesLib feesLib,
        address wrappedNativeAddress,
        ConnectorRegistry connectorRegistry
    ) ZapModule(factory, feesLib, wrappedNativeAddress, connectorRegistry) { }

    struct ClaimParams {
        address claimContractAddress;
        bytes claimExtraData;
    }

    struct CompoundParams {
        ClaimParams[] claimParams;
        address[] rewardTokens;
        ZapModule.ZapInData zapData;
        address depositContractAddress;
        bytes depositExtraData;
    }

    struct HarvestParams {
        ClaimParams[] claimParams;
        SwapData[] swaps;
        address[] tokensOut;
    }

    function compoundMultiple(
        CompoundParams calldata params,
        address[] memory sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);

        uint256 arrayLength = params.claimParams.length + 4;
        address[] memory targets = new address[](arrayLength);
        bytes[] memory data = new bytes[](arrayLength);

        uint256 i = 0;
        for (; i < params.claimParams.length; i++) {
            ClaimParams calldata claimParams = params.claimParams[i];
            address farmConnector =
                connectorRegistry.connectorOf(claimParams.claimContractAddress);

            targets[i] = farmConnector;
            data[i] = abi.encodeCall(
                IFarmConnector.claim,
                (claimParams.claimContractAddress, claimParams.claimExtraData)
            );
        }

        targets[i] = address(this);
        data[i] = abi.encodeCall(
            this._sickle_charge_fees,
            (address(this), MultiFarmStrategyFees.Compound, params.rewardTokens)
        );

        targets[i + 1] = address(this);
        data[i + 1] = abi.encodeCall(ZapModule._sickle_zap_in, (params.zapData));

        address depositFarmConnector =
            connectorRegistry.connectorOf(params.depositContractAddress);
        targets[i + 2] = depositFarmConnector;
        data[i + 2] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                params.depositContractAddress,
                params.zapData.addLiquidityData.lpToken,
                params.depositExtraData
            )
        );

        targets[i + 3] = address(this);
        data[i + 3] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }

    function harvestMultiple(
        HarvestParams calldata params,
        address[] memory sweepTokens
    ) public {
        Sickle sickle = getSickle(msg.sender);

        uint256 arrayLength = params.claimParams.length + 3;

        address[] memory targets = new address[](arrayLength);
        bytes[] memory data = new bytes[](arrayLength);

        uint256 i;
        for (; i < params.claimParams.length; i++) {
            address farmConnector = connectorRegistry.connectorOf(
                params.claimParams[i].claimContractAddress
            );

            targets[i] = farmConnector;
            data[i] = abi.encodeCall(
                IFarmConnector.claim,
                (
                    params.claimParams[i].claimContractAddress,
                    params.claimParams[i].claimExtraData
                )
            );
        }

        targets[i] = address(this);
        data[i] =
            abi.encodeCall(SwapModule._sickle_swap_multiple, (params.swaps));
        targets[i + 1] = address(this);
        data[i + 1] = abi.encodeCall(
            this._sickle_charge_fees,
            (address(this), MultiFarmStrategyFees.Harvest, params.tokensOut)
        );

        targets[i + 2] = address(this);
        data[i + 2] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }
}
