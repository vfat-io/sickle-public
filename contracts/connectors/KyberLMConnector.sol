// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";

struct KyberLMClaimExtraData {
    bytes kyberCallData;
    bytes feeClaimExtraData;
}

contract KyberLMConnector is INftFarmConnector, DelegateModule {
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
        KyberLMClaimExtraData memory claimExtraData =
            abi.decode(extraData, (KyberLMClaimExtraData));

        // Claim Kyber LM rewards if callData is provided
        if (claimExtraData.kyberCallData.length > 0) {
            (bool success,) = position.farm.stakingContract.call(
                claimExtraData.kyberCallData
            );
            require(success, "KyberLM claim failed");
        }

        // Claim underlying Uniswap V4 swap fees
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
        // Kyber LM V4 NFTs are not staked
        return false;
    }
}
