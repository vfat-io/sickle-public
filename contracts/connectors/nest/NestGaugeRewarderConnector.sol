// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

interface IGaugeRewarder {
    function claim(
        uint256 totalAmount_,
        uint256 deadline_,
        bytes calldata signature_
    ) external;

    function claimed(address user) external view returns (uint256);

    function token() external view returns (address);
}

struct NestClaimExtraData {
    uint256 totalAmount;
    uint256 deadline;
    bytes signature;
}

/// @title NestGaugeRewarderConnector
/// @notice Connector for Nest V3 rewards via signature-based GaugeRewarder
/// @dev NFTs are not staked - rewards are calculated off-chain and claimed
/// with signatures. Fee collection is handled separately.
contract NestGaugeRewarderConnector is INftFarmConnector {
    function claim(
        NftPosition calldata position,
        address[] memory,
        uint128,
        uint128,
        bytes calldata extraData
    ) external override {
        if (extraData.length == 0) return;

        NestClaimExtraData memory claimData =
            abi.decode(extraData, (NestClaimExtraData));

        if (claimData.signature.length == 0) return;

        IGaugeRewarder(position.farm.stakingContract).claim(
            claimData.totalAmount,
            claimData.deadline,
            claimData.signature
        );
    }

    function depositExistingNft(
        NftPosition calldata,
        bytes calldata
    ) external override {
        // No-op: Nest V3 NFTs are not staked, rewards are tracked off-chain
    }

    function withdrawNft(
        NftPosition calldata,
        bytes calldata
    ) external override {
        // No-op: Nest V3 NFTs are not staked
    }

    function earned(
        address,
        NftPosition calldata,
        address[] memory rewardTokens
    ) external pure override returns (uint256[] memory) {
        // Off-chain rewards - actual pending rewards need off-chain API
        return new uint256[](rewardTokens.length);
    }

    function isStaked(
        address,
        NftPosition calldata
    ) external pure override returns (bool) {
        // Nest V3 NFTs are not staked in the traditional sense
        return false;
    }
}
