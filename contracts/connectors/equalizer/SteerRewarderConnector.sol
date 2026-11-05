// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";
import { ISteerSmartRewarder } from
    "contracts/interfaces/external/equalizer/ISteerSmartRewarder.sol";

struct SteerClaimExtraData {
    uint256[] campaignIds;
    uint256[] amounts;
    bytes32[][] proofs;
    bytes feeClaimExtraData;
}

contract SteerRewarderConnector is INftFarmConnector, DelegateModule {
    ConnectorRegistry public immutable connectorRegistry;

    constructor(
        ConnectorRegistry _connectorRegistry
    ) {
        connectorRegistry = _connectorRegistry;
    }

    function claim(
        NftPosition calldata position,
        address[] memory rewardTokens,
        uint128 maxAmount0,
        uint128 maxAmount1,
        bytes calldata extraData
    ) external override {
        SteerClaimExtraData memory claimExtraData =
            abi.decode(extraData, (SteerClaimExtraData));

        address[] memory users =
            new address[](claimExtraData.campaignIds.length);
        for (uint256 i; i < claimExtraData.campaignIds.length;) {
            users[i] = address(this);
            unchecked {
                i++;
            }
        }

        ISteerSmartRewarder(position.farm.stakingContract).claim(
            users,
            claimExtraData.campaignIds,
            claimExtraData.amounts,
            claimExtraData.proofs
        );

        INftFarmConnector connector = INftFarmConnector(
            connectorRegistry.connectorOf(address(position.nft))
        );
        _delegateToConnector(
            address(connector),
            abi.encodeCall(
                INftFarmConnector.claim,
                (
                    position,
                    rewardTokens,
                    maxAmount0,
                    maxAmount1,
                    claimExtraData.feeClaimExtraData
                )
            )
        );
    }

    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external override { }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external override { }

    function earned(
        address, // user
        NftPosition calldata,
        address[] memory rewardTokens
    ) external pure override returns (uint256[] memory) {
        return new uint256[](rewardTokens.length);
    }

    function isStaked(
        address, // user
        NftPosition calldata
    ) external pure override returns (bool) {
        return false;
    }
}
