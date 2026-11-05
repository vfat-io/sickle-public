// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";
import {
    IDistribution
} from "contracts/interfaces/external/merkl/IDistribution.sol";
import { MerklClaimExtraData } from "contracts/structs/MerklStructs.sol";

contract MerklConnector is INftFarmConnector, IFarmConnector, DelegateModule {
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
        MerklClaimExtraData memory claimExtraData =
            abi.decode(extraData, (MerklClaimExtraData));

        address[] memory users =
            new address[](claimExtraData.claimTokens.length);
        for (uint256 i; i < claimExtraData.claimTokens.length;) {
            users[i] = address(this);
            unchecked {
                i++;
            }
        }

        IDistribution(position.farm.stakingContract)
            .claim(
                users,
                claimExtraData.claimTokens,
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
        // Merkl V3 - V4 NFTs are not staked
        return false;
    }

    /* IFarmConnector - For ERC20 Farm Positions */

    function deposit(
        Farm calldata,
        address, // token
        bytes calldata // extraData
    ) external override {
        // Merkl doesn't require staking for ERC20 positions
        // No-op: just hold the LP tokens in the Sickle
    }

    function withdraw(
        Farm calldata,
        uint256, // amount
        bytes calldata // extraData
    ) external override {
        // Merkl doesn't require unstaking for ERC20 positions
        // No-op: tokens are already in the Sickle
    }

    function claim(
        Farm calldata farm,
        bytes calldata extraData
    ) external override {
        MerklClaimExtraData memory claimExtraData =
            abi.decode(extraData, (MerklClaimExtraData));

        address[] memory users =
            new address[](claimExtraData.claimTokens.length);
        for (uint256 i; i < claimExtraData.claimTokens.length;) {
            users[i] = address(this);
            unchecked {
                i++;
            }
        }

        IDistribution(farm.stakingContract)
            .claim(
                users,
                claimExtraData.claimTokens,
                claimExtraData.amounts,
                claimExtraData.proofs
            );
    }

    function balanceOf(
        Farm calldata, // farm
        address // user
    ) external pure override returns (uint256) {
        // Merkl doesn't track staked balance, just LP token ownership
        // Return 0 or implement actual LP token balance check if needed
        return 0;
    }

    function earned(
        Farm calldata, // farm
        address, // user
        address[] calldata rewardTokens
    ) external pure override returns (uint256[] memory) {
        // Merkl rewards are off-chain, return zeros
        return new uint256[](rewardTokens.length);
    }

    function isStaked(
        Farm calldata, // farm
        address // user
    ) external pure override returns (bool) {
        // Merkl ERC20 positions don't require staking
        return false;
    }
}
