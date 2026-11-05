// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    ICurveChildGaugeFactory
} from "contracts/interfaces/external/curve/ICurveChildGaugeFactory.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

/// @notice Connector for Curve child gauges on CRV-emitting sidechains.
/// @dev This is deliberately separate from Ethereum's `CurveGaugeConnector`:
/// child factories do not share the Ethereum Minter's `token()`/`controller()`
/// ABI, and claimable CRV is accounted by the gauge and its own factory.
/// Factory addresses are immutables because connectors execute by delegatecall
/// and therefore cannot safely rely on connector storage.
contract CurveSidechainGaugeConnector is IFarmConnector {
    error InvalidCrv();
    error InvalidChildGaugeFactory();
    error DuplicateChildGaugeFactory();
    error InvalidChildGauge(address gauge);

    address public immutable crv;
    address public immutable childGaugeFactory;
    address public immutable legacyChildGaugeFactory;

    constructor(
        address crv_,
        address childGaugeFactory_,
        address legacyChildGaugeFactory_
    ) {
        if (crv_ == address(0)) revert InvalidCrv();
        if (childGaugeFactory_ == address(0)) {
            revert InvalidChildGaugeFactory();
        }
        if (legacyChildGaugeFactory_ == childGaugeFactory_) {
            revert DuplicateChildGaugeFactory();
        }

        crv = crv_;
        childGaugeFactory = childGaugeFactory_;
        legacyChildGaugeFactory = legacyChildGaugeFactory_;
    }

    /// @notice Return the configured factory that deployed `gauge`, or zero
    /// when the gauge is not validated by either authorized factory.
    function factoryOf(
        address gauge
    ) public view returns (address factory) {
        (bool ok, bytes memory data) = gauge.staticcall(
            abi.encodeWithSelector(ICurveGauge.factory.selector)
        );
        if (!ok || data.length != 32) return address(0);

        factory = abi.decode(data, (address));
        if (factory != childGaugeFactory && factory != legacyChildGaugeFactory)
        {
            return address(0);
        }

        (ok, data) = factory.staticcall(
            abi.encodeWithSelector(
                ICurveChildGaugeFactory.is_valid_gauge.selector, gauge
            )
        );
        if (!ok || data.length != 32 || !abi.decode(data, (bool))) {
            return address(0);
        }
    }

    function isValidGauge(
        address gauge
    ) external view returns (bool) {
        return factoryOf(gauge) != address(0);
    }

    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // extraData
    ) external override {
        if (
            farm.poolIndex != 0
                || token != ICurveGauge(farm.stakingContract).lp_token()
        ) {
            revert InvalidChildGauge(farm.stakingContract);
        }
        _requireFactory(farm.stakingContract);

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
        bytes memory // extraData
    ) external override {
        _requireFactory(farm.stakingContract);
        ICurveGauge(farm.stakingContract).withdraw(amount);
    }

    function claim(
        Farm calldata farm,
        bytes memory // extraData
    ) external override {
        address factory = _requireFactory(farm.stakingContract);
        ICurveChildGaugeFactory(factory).mint(farm.stakingContract);
        ICurveGauge(farm.stakingContract).claim_rewards();
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        _requireFactory(farm.stakingContract);
        return ICurveGauge(farm.stakingContract).balanceOf(user);
    }

    /// @notice Return checkpointed CRV plus the gauge's extra reward tokens.
    /// @dev The child factory mints `integrate_fraction(user) - minted` after
    /// first checkpointing the gauge. A view cannot perform that checkpoint,
    /// so this reports the safe, already-checkpointed amount. Clamp to zero if
    /// an inconsistent or migrated factory reports a larger minted total.
    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory rewards) {
        address gauge = farm.stakingContract;
        address factory = _requireFactory(gauge);

        rewards = new uint256[](rewardTokens.length);
        for (uint256 i; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == crv) {
                uint256 integrated = ICurveGauge(gauge).integrate_fraction(user);
                uint256 alreadyMinted =
                    ICurveChildGaugeFactory(factory).minted(user, gauge);
                rewards[i] =
                    integrated > alreadyMinted ? integrated - alreadyMinted : 0;
            } else {
                rewards[i] =
                    ICurveGauge(gauge).claimable_reward(user, rewardTokens[i]);
            }
        }
    }

    function isStaked(
        Farm calldata,
        address // user
    ) external pure override returns (bool) {
        return true;
    }

    function _requireFactory(
        address gauge
    ) private view returns (address factory) {
        factory = factoryOf(gauge);
        if (factory == address(0)) revert InvalidChildGauge(gauge);
    }
}
