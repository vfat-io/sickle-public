// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";
import {
    ICurveMinter
} from "contracts/interfaces/external/curve/ICurveMinter.sol";
import {
    CurveCrvRewards
} from "contracts/connectors/curve/CurveCrvRewards.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

contract CurveGaugeConnector is IFarmConnector {
    error InvalidGaugeDeposit();
    /// @notice Contract that mints a gauge's accrued CRV to the caller, or the
    /// zero address where there is no CRV to mint.
    /// @dev Ethereum uses the standalone Curve Minter. Sidechain child gauges
    /// are handled by `CurveSidechainGaugeConnector`.
    address public immutable minter;

    /// @notice The token `minter` emits, and the GaugeController it prices
    /// gauge weights against. Both zero when there is no minter.
    address public immutable crv;
    address public immutable gaugeController;

    constructor(
        address minter_
    ) {
        minter = minter_;
        (address crv_, address gaugeController_) = _minterConfig(minter_);
        crv = crv_;
        gaugeController = gaugeController_;
    }

    /// @dev Solidity forbids assigning an immutable inside a conditional, so
    /// resolve both together and assign unconditionally.
    function _minterConfig(
        address minter_
    ) private view returns (address, address) {
        if (minter_ == address(0)) {
            return (address(0), address(0));
        }
        return
            (ICurveMinter(minter_).token(), ICurveMinter(minter_).controller());
    }

    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // _extraData
    ) external override {
        if (
            farm.poolIndex != 0
                || token != ICurveGauge(farm.stakingContract).lp_token()
        ) {
            revert InvalidGaugeDeposit();
        }
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            SafeTransferLib.safeApprove(token, farm.stakingContract, 0);
            SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
            ICurveGauge(farm.stakingContract).deposit(amount);
            SafeTransferLib.safeApprove(token, farm.stakingContract, 0);
        }
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // _extraData
    ) external override {
        ICurveGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory // extraData
    ) external override {
        // `claim_rewards` only pays the gauge's extra reward tokens. CRV
        // accrues to the staker -- here the Sickle -- and only the staker can
        // mint it, so without this the Sickle's CRV would be unreachable.
        if (minter != address(0)) {
            ICurveMinter(minter).mint(farm.stakingContract);
        }
        ICurveGauge(farm.stakingContract).claim_rewards();
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return ICurveGauge(farm.stakingContract).balanceOf(user);
    }

    /// @notice Claimable rewards, covering both what `claim()` pays: the
    /// gauge's extra reward tokens, and the Minter's CRV emission.
    /// @dev CRV needs its own path. It is not one of the gauge's extra reward
    /// tokens, so `claimable_reward` reports nothing for it, and Curve's
    /// authoritative `claimable_tokens` checkpoints as it reads and so cannot
    /// be called from a `view`. `CurveCrvRewards` reproduces its arithmetic
    /// from public state; see that library for the one input it cannot read
    /// and why the result errs low rather than high.
    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == crv && minter != address(0)) {
                rewards[i] = CurveCrvRewards.claimable(
                    farm.stakingContract, user, gaugeController, minter, crv
                );
            } else {
                rewards[i] = ICurveGauge(farm.stakingContract)
                    .claimable_reward(user, rewardTokens[i]);
            }
        }
        return rewards;
    }

    function isStaked(
        Farm calldata,
        address // user
    ) external pure override returns (bool) {
        return true;
    }
}
