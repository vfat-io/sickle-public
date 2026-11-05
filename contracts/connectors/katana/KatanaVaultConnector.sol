// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from
    "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC4626 } from
    "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

/// @title KatanaVaultConnector
/// @notice Connector for the avKAT ERC4626 vault on Katana Network.
/// After the StakingRouter executes a pre-commit, the Sickle holds avKAT
/// shares. This connector tracks the vault position and allows depositing
/// additional KAT.
/// @dev The avKAT vault's redeem() does NOT return KAT as an ERC20 transfer.
/// It routes through VotingEscrow lock/split mechanics (NFT-based exit).
/// Therefore withdraw() is a no-op — the avKAT shares are already ERC20
/// tokens held by the Sickle. To exit, the strategy should call
/// simpleWithdraw with lpToken = avKAT vault address to transfer avKAT
/// shares back to the user.
/// Farm.stakingContract should be set to the avKAT vault address.
contract KatanaVaultConnector is IFarmConnector {
    error InvalidToken();

    /// @notice Deposits KAT into the avKAT vault.
    /// @dev Approves and deposits the full KAT balance of the Sickle.
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // extraData
    ) external override {
        address asset = IERC4626(farm.stakingContract).asset();
        if (token != asset) revert InvalidToken();

        uint256 amount = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
        IERC4626(farm.stakingContract).deposit(amount, address(this));
    }

    /// @notice No-op: avKAT shares are already held by the Sickle as ERC20.
    /// @dev The vault's redeem() routes through VotingEscrow lock mechanics
    /// and does not produce a clean ERC20 KAT return. To withdraw, the
    /// strategy should transfer avKAT shares (lpToken = vault address)
    /// back to the user via TransferLib.
    function withdraw(
        Farm calldata, // farm
        uint256, // amount
        bytes memory // extraData
    ) external pure override { }

    /// @notice No rewards to claim — avKAT autocompounds.
    function claim(
        Farm calldata, // farm
        bytes memory // extraData
    ) external pure override { }

    /// @notice Returns the avKAT share balance of the user.
    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IERC20(farm.stakingContract).balanceOf(user);
    }

    /// @notice No separate reward tokens — yield is autocompounded into shares.
    function earned(
        Farm calldata,
        address,
        address[] calldata
    ) external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    /// @notice Returns true if the user holds avKAT shares.
    function isStaked(
        Farm calldata farm,
        address user
    ) external view override returns (bool) {
        return IERC20(farm.stakingContract).balanceOf(user) > 0;
    }
}
