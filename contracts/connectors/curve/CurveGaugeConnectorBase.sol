// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";
import {
    ICurveMinter
} from "contracts/interfaces/external/curve/ICurveMinter.sol";
import {
    ICurveLiquidityResolver
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    CurveCrvRewards
} from "contracts/connectors/curve/CurveCrvRewards.sol";
import { CurveGaugeIdentity } from "./CurveGaugeIdentity.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

interface ICurveLegacyGauge {
    function minter() external view returns (address);
    function controller() external view returns (address);
    function rewarded_token() external view returns (address);
    function reward_integral(
        address token
    ) external view returns (uint256);
    function reward_integral_for(
        address token,
        address user
    ) external view returns (uint256);
    function claimable_reward(
        address user
    ) external view returns (uint256);
    function claimed_rewards_for(
        address user
    ) external view returns (uint256);
}

enum CurveGaugeRewards {
    None,
    Single,
    FixedV2,
    FixedV3,
    Modern
}

struct CurveGaugeInfo {
    address lpToken;
    CurveGaugeRewards rewards;
    bool minterEmission;
    bool transferable;
    bool killed;
    bool newStakingReady;
}

/// @notice Curve registry and GaugeController authenticated Ethereum gauges.
/// @dev Called by delegatecall for mutations: the Sickle owns the stake and
/// receives rewards. All configuration is immutable; no Sickle storage is
/// written.
abstract contract CurveGaugeConnectorBase is IFarmConnector {
    error UnsupportedGauge(address gauge);
    error InvalidGaugeDeposit();

    ICurveLiquidityResolver public immutable resolver;
    address public immutable minter;
    address public immutable crv;
    address public immutable gaugeController;

    constructor(
        ICurveLiquidityResolver resolver_,
        address minter_
    ) {
        resolver = resolver_;
        minter = minter_;
        crv = ICurveMinter(minter_).token();
        gaugeController = ICurveMinter(minter_).controller();
    }

    function deposit(
        Farm calldata farm,
        address token,
        bytes memory
    ) external override {
        (address lp, bool current,) = _farmIdentity(farm);
        if (token != lp || !current || isKilled(farm.stakingContract)) {
            revert InvalidGaugeDeposit();
        }
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        SafeTransferLib.safeApprove(token, farm.stakingContract, 0);
        SafeTransferLib.safeApprove(token, farm.stakingContract, amount);
        ICurveGauge(farm.stakingContract).deposit(amount);
        SafeTransferLib.safeApprove(token, farm.stakingContract, 0);
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory
    ) external override {
        _farmIdentity(farm);
        ICurveGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory
    ) external override {
        (,, bool emissions) = _farmIdentity(farm);
        if (emissions) ICurveMinter(minter).mint(farm.stakingContract);
        _claimExtra(farm.stakingContract);
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        _farmIdentity(farm);
        return ICurveGauge(farm.stakingContract).balanceOf(user);
    }

    /// @notice CRV and legacy external rewards are conservative claimable
    /// bounds. V2's claimable_reward writes checkpoints, so read its public
    /// integral instead.
    function earned(
        Farm calldata farm,
        address user,
        address[] calldata tokens
    ) external view override returns (uint256[] memory amounts) {
        (,, bool emissions) = _farmIdentity(farm);
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            if (tokens[i] == crv && emissions) {
                amounts[i] = CurveCrvRewards.claimable(
                    farm.stakingContract,
                    user,
                    gaugeController,
                    minter,
                    crv,
                    isKilled(farm.stakingContract)
                );
            } else {
                amounts[i] = _extraEarned(farm.stakingContract, user, tokens[i]);
            }
        }
    }

    function isStaked(
        Farm calldata,
        address
    ) external pure override returns (bool) {
        return true;
    }

    function gaugeInfo(
        address gauge
    ) public view returns (CurveGaugeInfo memory info) {
        bool current;
        (info.lpToken, current, info.minterEmission) =
            CurveGaugeIdentity.resolve(resolver, gaugeController, gauge);
        info.rewards = rewardType();
        info.transferable =
            uint256(info.rewards) >= uint256(CurveGaugeRewards.FixedV2);
        info.killed = isKilled(gauge);
        info.newStakingReady = current && !info.killed;
    }

    function rewardType() public pure virtual returns (CurveGaugeRewards);

    function isKilled(
        address gauge
    ) public view virtual returns (bool) {
        return ICurveGauge(gauge).is_killed();
    }
    function _claimExtra(
        address gauge
    ) internal virtual;
    function _extraEarned(
        address gauge,
        address user,
        address token
    ) internal view virtual returns (uint256);

    function _farmIdentity(
        Farm calldata farm
    ) private view returns (address lp, bool current, bool emissions) {
        if (farm.poolIndex != 0) revert UnsupportedGauge(farm.stakingContract);
        return CurveGaugeIdentity.resolve(
            resolver, gaugeController, farm.stakingContract
        );
    }
}
