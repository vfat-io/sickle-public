// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./modules/NftTransferModule.sol";
import "../interfaces/IFarmConnector.sol";
import "../ConnectorRegistry.sol";

library NftFarmStrategyFees {
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
}

contract NftFarmStrategy is NftTransferModule {
    ConnectorRegistry public immutable connectorRegistry;

    constructor(
        SickleFactory factory,
        FeesLib feesLib,
        address wrappedNativeAddress,
        ConnectorRegistry connectorRegistry_
    ) NftTransferModule(factory, feesLib, wrappedNativeAddress) {
        connectorRegistry = connectorRegistry_;
    }

    function depositErc721(
        address nftContractAddress,
        uint256 tokenId,
        address stakingContractAddress,
        bytes memory extraData,
        address approved,
        bytes32 referralCode
    ) public {
        Sickle sickle = Sickle(
            payable(factory.getOrDeploy(msg.sender, approved, referralCode))
        );

        address farmConnector =
            connectorRegistry.connectorOf(stakingContractAddress);

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = address(this);
        data[0] = abi.encodeCall(
            this._sickle_transfer_nft_from_user, (nftContractAddress, tokenId)
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

        targets[2] = address(this);
        data[2] = abi.encodeCall(
            this._sickle_transfer_nft_to_user, (nftContractAddress, tokenId)
        );

        targets[3] = address(this);
        data[3] = abi.encodeCall(
            this._sickle_charge_fees,
            (address(this), NftFarmStrategyFees.Harvest, rewardTokens)
        );

        targets[4] = address(this);
        data[4] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (rewardTokens));

        sickle.multicall(targets, data);
    }
}
