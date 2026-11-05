// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";

interface IHydrexIncentiveDistributor {
    function claimRewards(
        bytes32 campaignId,
        address beneficiary,
        uint256 cumulativeAmount,
        bytes32[] calldata merkleProof
    ) external;

    function claimMultiple(
        bytes32[] calldata campaignIds,
        uint256[] calldata cumulativeAmounts,
        bytes32[][] calldata merkleProofs
    ) external returns (bool[] memory successes);
}

struct HydrexMerklClaimExtraData {
    bytes32[] campaignIds;
    uint256[] cumulativeAmounts;
    bytes32[][] merkleProofs;
    bool useSingleClaim;
    bytes feeClaimExtraData;
}

contract HydrexMerklConnector is INftFarmConnector, IFarmConnector, DelegateModule {
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
        HydrexMerklClaimExtraData memory claimExtraData =
            abi.decode(extraData, (HydrexMerklClaimExtraData));

        _claimHydrex(position.farm.stakingContract, claimExtraData);

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
        NftPosition calldata,
        bytes calldata
    ) external override { }

    function withdrawNft(
        NftPosition calldata,
        bytes calldata
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
        // Hydrex/Merkl V3-V4 NFTs are not staked.
        return false;
    }

    /* IFarmConnector - For ERC20 Farm Positions */

    function deposit(
        Farm calldata,
        address, // token
        bytes calldata // extraData
    ) external override {
        // Hydrex/Merkl doesn't require staking for ERC20 positions.
    }

    function withdraw(
        Farm calldata,
        uint256, // amount
        bytes calldata // extraData
    ) external override {
        // Hydrex/Merkl doesn't require unstaking for ERC20 positions.
    }

    function claim(
        Farm calldata farm,
        bytes calldata extraData
    ) external override {
        HydrexMerklClaimExtraData memory claimExtraData =
            abi.decode(extraData, (HydrexMerklClaimExtraData));
        _claimHydrex(farm.stakingContract, claimExtraData);
    }

    function balanceOf(
        Farm calldata, // farm
        address // user
    ) external pure override returns (uint256) {
        // Rewards are off-chain via merkle proofs.
        return 0;
    }

    function earned(
        Farm calldata, // farm
        address, // user
        address[] calldata rewardTokens
    ) external pure override returns (uint256[] memory) {
        // Rewards are off-chain via merkle proofs.
        return new uint256[](rewardTokens.length);
    }

    function isStaked(
        Farm calldata, // farm
        address // user
    ) external pure override returns (bool) {
        // Hydrex/Merkl ERC20 positions don't require staking.
        return false;
    }

    function _claimHydrex(
        address distributor,
        HydrexMerklClaimExtraData memory claimExtraData
    ) internal {
        IHydrexIncentiveDistributor hydrexDistributor =
            IHydrexIncentiveDistributor(distributor);

        if (claimExtraData.useSingleClaim) {
            require(claimExtraData.campaignIds.length == 1, "single-claim-length");
            require(claimExtraData.cumulativeAmounts.length == 1, "single-amount-length");
            require(claimExtraData.merkleProofs.length == 1, "single-proof-length");

            hydrexDistributor.claimRewards(
                claimExtraData.campaignIds[0],
                address(this),
                claimExtraData.cumulativeAmounts[0],
                claimExtraData.merkleProofs[0]
            );
            return;
        }

        require(
            claimExtraData.campaignIds.length == claimExtraData.cumulativeAmounts.length
                && claimExtraData.campaignIds.length == claimExtraData.merkleProofs.length,
            "length-mismatch"
        );

        bool[] memory successes = hydrexDistributor.claimMultiple(
            claimExtraData.campaignIds,
            claimExtraData.cumulativeAmounts,
            claimExtraData.merkleProofs
        );

        for (uint256 i; i < successes.length;) {
            require(successes[i], "claim-multiple-failed");
            unchecked {
                i++;
            }
        }
    }
}
