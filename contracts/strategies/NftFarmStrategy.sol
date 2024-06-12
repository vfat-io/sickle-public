// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { NftTransferLib } from "contracts/libraries/NftTransferLib.sol";
import { FeesLib } from "contracts/libraries/FeesLib.sol";
import { TransferLib } from "contracts/libraries/TransferLib.sol";
import {
    StrategyModule,
    SickleFactory,
    Sickle
} from "contracts/modules/StrategyModule.sol";
import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";

library NftFarmStrategyFees {
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
}

contract NftFarmStrategy is StrategyModule {
    struct Libraries {
        NftTransferLib nftTransferLib;
        FeesLib feesLib;
        TransferLib transferLib;
    }

    NftTransferLib public immutable nftTransferLib;
    FeesLib public immutable feesLib;
    TransferLib public immutable transferLib;

    address public immutable strategyAddress;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        Libraries memory libraries
    ) StrategyModule(factory, connectorRegistry) {
        nftTransferLib = libraries.nftTransferLib;
        feesLib = libraries.feesLib;
        transferLib = libraries.transferLib;
        strategyAddress = address(this);
    }

    function depositErc721(
        address nftContractAddress,
        uint256 tokenId,
        address stakingContractAddress,
        bytes memory extraData,
        address approved,
        bytes32 referralCode
    ) public {
        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);

        address farmConnector =
            connectorRegistry.connectorOf(stakingContractAddress);

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = address(nftTransferLib);
        data[0] = abi.encodeCall(
            NftTransferLib.transferErc721FromUser, (nftContractAddress, tokenId)
        );

        targets[1] = farmConnector;
        data[1] = abi.encodeCall(
            IFarmConnector.deposit,
            (stakingContractAddress, nftContractAddress, extraData)
        );

        sickle.multicall(targets, data);
    }

    function withdrawErc721(
        address nftContractAddress,
        uint256 tokenId,
        address stakingContractAddress,
        bytes memory extraData,
        address[] calldata rewardTokens
    ) public {
        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](5);
        bytes[] memory data = new bytes[](5);

        address farmConnector =
            connectorRegistry.connectorOf(stakingContractAddress);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.claim, (stakingContractAddress, extraData)
        );

        targets[1] = farmConnector;
        data[1] = abi.encodeCall(
            IFarmConnector.withdraw,
            (stakingContractAddress, tokenId, extraData)
        );

        targets[2] = address(nftTransferLib);
        data[2] = abi.encodeCall(
            NftTransferLib.transferErc721ToUser, (nftContractAddress, tokenId)
        );

        targets[3] = address(feesLib);
        data[3] = abi.encodeCall(
            FeesLib.chargeFees,
            (strategyAddress, NftFarmStrategyFees.Harvest, rewardTokens)
        );

        targets[4] = address(transferLib);
        data[4] =
            abi.encodeCall(TransferLib.transferTokensToUser, (rewardTokens));

        sickle.multicall(targets, data);
    }
}
