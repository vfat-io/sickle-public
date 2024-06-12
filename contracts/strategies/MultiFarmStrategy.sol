// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import {
    StrategyModule,
    SickleFactory,
    Sickle
} from "contracts/modules/StrategyModule.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { ZapLib, ZapInData } from "contracts/libraries/ZapLib.sol";
import { FeesLib } from "contracts/libraries/FeesLib.sol";
import { TransferLib } from "contracts/libraries/TransferLib.sol";
import { SwapLib } from "contracts/libraries/SwapLib.sol";
import { SwapData } from "contracts/interfaces/ILiquidityConnector.sol";

library MultiFarmStrategyFees {
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
    bytes4 constant Compound = bytes4(keccak256("FarmCompoundFee"));
}

contract MultiFarmStrategy is StrategyModule {
    struct ClaimParams {
        address claimContractAddress;
        bytes claimExtraData;
    }

    struct CompoundParams {
        ClaimParams[] claimParams;
        address[] rewardTokens;
        ZapInData zapData;
        address depositContractAddress;
        bytes depositExtraData;
    }

    struct HarvestParams {
        ClaimParams[] claimParams;
        SwapData[] swaps;
        address[] tokensOut;
    }

    struct Libraries {
        TransferLib transferLib;
        SwapLib swapLib;
        FeesLib feesLib;
        ZapLib zapLib;
    }

    TransferLib public immutable transferLib;
    SwapLib public immutable swapLib;
    FeesLib public immutable feesLib;
    ZapLib public immutable zapLib;

    address public immutable strategyAddress;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        Libraries memory libraries
    ) StrategyModule(factory, connectorRegistry) {
        strategyAddress = address(this);
        transferLib = libraries.transferLib;
        swapLib = libraries.swapLib;
        feesLib = libraries.feesLib;
        zapLib = libraries.zapLib;
    }

    function compoundMultiple(
        CompoundParams calldata params,
        address[] memory sweepTokens
    ) external {
        Sickle sickle = getSickle(msg.sender);

        uint256 arrayLength = params.claimParams.length + 4;
        address[] memory targets = new address[](arrayLength);
        bytes[] memory data = new bytes[](arrayLength);

        uint256 i;
        uint256 length = params.claimParams.length;
        for (; i < length;) {
            ClaimParams calldata claimParams = params.claimParams[i];
            address farmConnector =
                connectorRegistry.connectorOf(claimParams.claimContractAddress);

            targets[i] = farmConnector;
            data[i] = abi.encodeCall(
                IFarmConnector.claim,
                (claimParams.claimContractAddress, claimParams.claimExtraData)
            );

            unchecked {
                i++;
            }
        }

        targets[i] = address(feesLib);
        data[i] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                MultiFarmStrategyFees.Compound,
                params.rewardTokens
            )
        );

        targets[i + 1] = address(zapLib);
        data[i + 1] = abi.encodeCall(ZapLib.zapIn, (params.zapData));

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

        if (sweepTokens.length > 0) {
            targets[i + 3] = address(transferLib);
            data[i + 3] =
                abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));
        }

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
        uint256 length = params.claimParams.length;
        for (; i < length;) {
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

            unchecked {
                i++;
            }
        }

        targets[i] = address(swapLib);
        data[i] = abi.encodeCall(SwapLib.swapMultiple, (params.swaps));
        targets[i + 1] = address(feesLib);
        data[i + 1] = abi.encodeCall(
            FeesLib.chargeFees,
            (strategyAddress, MultiFarmStrategyFees.Harvest, params.tokensOut)
        );

        targets[i + 2] = address(transferLib);
        data[i + 2] =
            abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));

        sickle.multicall(targets, data);
    }
}
