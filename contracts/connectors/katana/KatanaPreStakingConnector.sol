// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from
    "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

/// @title KatanaPreStakingConnector
/// @notice Connector for Katana Network KAT pre-staking via StakingRouter
/// @dev Pre-staking works by approving KAT to the StakingRouter. A relayer
/// then calls executePreCommit(sickle) which pulls KAT and deposits into the
/// avKAT vault. Before execution, the user can revoke with zero penalty by
/// setting the approval to 0.
/// Farm.stakingContract should be set to the StakingRouter address.
/// NOTE: This connector only tracks the pre-stake phase (allowance-based).
/// Once the relayer executes the pre-commit, the allowance is spent and
/// balanceOf/isStaked will return 0. A separate connector will be needed
/// to track the resulting avKAT vault position post-execution.
contract KatanaPreStakingConnector is IFarmConnector {
    address public immutable katToken;

    error InvalidToken();

    constructor(
        address _katToken
    ) {
        katToken = _katToken;
    }

    /// @notice Pre-stakes KAT by approving the full balance to StakingRouter
    /// @dev The KAT tokens remain in the Sickle until a relayer executes
    /// the pre-commit via StakingRouter.executePreCommit(sickle)
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // extraData
    ) external override {
        if (token != katToken) revert InvalidToken();
        uint256 amount = IERC20(katToken).balanceOf(address(this));
        SafeTransferLib.safeApprove(katToken, farm.stakingContract, amount);
    }

    /// @notice Revokes the pre-staking approval (zero penalty before TGE)
    /// @dev Sets the KAT approval to StakingRouter back to 0.
    /// The KAT tokens are already in the Sickle and will be returned to the
    /// user by the strategy's transfer step.
    function withdraw(
        Farm calldata farm,
        uint256, // amount
        bytes memory // extraData
    ) external override {
        SafeTransferLib.safeApprove(katToken, farm.stakingContract, 0);
    }

    /// @notice No rewards during pre-staking period
    function claim(
        Farm calldata, // farm
        bytes memory // extraData
    ) external pure override { }

    /// @notice Returns the amount of KAT approved (pre-committed) to
    /// StakingRouter
    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IERC20(katToken).allowance(user, farm.stakingContract);
    }

    /// @notice No rewards during pre-staking period
    function earned(
        Farm calldata,
        address,
        address[] calldata
    ) external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    /// @notice Returns true if the user has a non-zero pre-staking commitment
    function isStaked(
        Farm calldata farm,
        address user
    ) external view override returns (bool) {
        return IERC20(katToken).allowance(user, farm.stakingContract) > 0;
    }
}
