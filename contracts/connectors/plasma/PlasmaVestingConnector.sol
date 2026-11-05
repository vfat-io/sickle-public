// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";

struct AddressInfo {
    address receiver;
    uint256 toPay;
    uint256 paid;
    bool pause;
    uint256 vestingInterval;
    uint256 vestingStart;
}

interface IPlasmaPrivateVesting {
    function claim() external returns (uint256 tokenId);
    function getWithdrawAmount(
        address user
    ) external view returns (uint256);
    function getAddressInfo(
        address user
    ) external view returns (AddressInfo memory);
}

/// @title PlasmaVestingConnector
/// @notice Connector for claiming vested tokens from Lithos PrivateVesting
/// @dev This is a claim-only connector as the PrivateVesting contract
contract PlasmaVestingConnector is IFarmConnector {
    error NotImplemented();

    function deposit(
        Farm memory, // farm
        address, // token
        bytes memory // extraData
    ) external pure override {
        revert NotImplemented();
    }

    function withdraw(
        Farm memory, // farm
        uint256, // amount
        bytes memory // extraData
    ) external pure override {
        revert NotImplemented();
    }

    function balanceOf(
        Farm calldata,
        address // user
    ) external pure override returns (uint256) {
        return 0;
    }

    function isStaked(
        Farm calldata,
        address // user
    ) external pure override returns (bool) {
        return false;
    }

    function claim(
        Farm memory farm,
        bytes memory // extraData
    ) external override {
        IPlasmaPrivateVesting(farm.stakingContract).claim();
    }

    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        if (rewardTokens.length > 0) {
            rewards[0] = IPlasmaPrivateVesting(farm.stakingContract)
                .getWithdrawAmount(user);
        }
        return rewards;
    }
}
