// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    IDistribution
} from "contracts/interfaces/external/merkl/IDistribution.sol";
import { MerklClaimExtraData } from "contracts/structs/MerklStructs.sol";

/// @title MentoFarmConnector
/// @notice Farm connector for a Mento FPMM LP held in the Sickle. Merkl pays
/// LP holders, so nothing is staked and `Farm.stakingContract` is the LP
/// itself. Each pool therefore has its own position-settings key.
/// `MentoFPMMPoolRegistry` resolves factory pools to this connector.
contract MentoFarmConnector is IFarmConnector {
    error PoolMismatch(address stakingContract, address lpToken);

    IDistribution public immutable distributor;

    constructor(
        IDistribution distributor_
    ) {
        distributor = distributor_;
    }

    /// @dev Nothing to stake. The shared `Farm` strategies pass the zap's
    /// `lpToken` here without checking it against `farm`, so this pins it.
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory
    ) external pure override {
        if (token != farm.stakingContract) {
            revert PoolMismatch(farm.stakingContract, token);
        }
    }

    function withdraw(
        Farm calldata,
        uint256,
        bytes memory
    ) external pure override { }

    /// @dev Merkl accrues per account, so a claim pays the Sickle's rewards
    /// from every pool it holds. Empty `extraData` or an empty token list
    /// claims nothing, so harvest-then-withdraw exits work without a proof.
    function claim(
        Farm calldata,
        bytes memory extraData
    ) external override {
        if (extraData.length == 0) return;
        MerklClaimExtraData memory claimData =
            abi.decode(extraData, (MerklClaimExtraData));
        uint256 length = claimData.claimTokens.length;
        if (length == 0) return;

        address[] memory users = new address[](length);
        for (uint256 i; i < length; i++) {
            users[i] = address(this);
        }
        distributor.claim(
            users, claimData.claimTokens, claimData.amounts, claimData.proofs
        );
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IERC20(farm.stakingContract).balanceOf(user);
    }

    /// @dev Merkl rewards are computed off chain.
    function earned(
        Farm calldata,
        address,
        address[] calldata rewardTokens
    ) external pure override returns (uint256[] memory) {
        return new uint256[](rewardTokens.length);
    }

    function isStaked(
        Farm calldata,
        address
    ) external pure override returns (bool) {
        return false;
    }
}
