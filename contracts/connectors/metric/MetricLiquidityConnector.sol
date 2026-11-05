// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import {
    IMetricOmmFactory,
    IMetricOmmPool,
    IMetricOmmLiquidityAdder,
    IMetricOmmDataProvider,
    MetricPoolImmutables,
    MetricLiquidityDelta
} from "contracts/interfaces/external/metric/IMetricOmm.sol";
import {
    IMetricLiquidityConnector
} from "contracts/interfaces/IMetricLiquidityConnector.sol";
import {
    MetricAddLiquidity,
    MetricRemoveLiquidity,
    MetricPosition
} from "contracts/structs/MetricStrategyStructs.sol";

/// @notice Metric liquidity operations for Sickle-owned positions.
/// @dev Delegatecalled; Metric's adder handles deposit callbacks.
contract MetricLiquidityConnector is IMetricLiquidityConnector {
    struct AddState {
        uint256 balance0;
        uint256 balance1;
        uint256 cap0;
        uint256 cap1;
        uint256[] beforeShares;
    }
    error InvalidDependency();
    error OnlyDelegateCall();
    error InvalidPool(address pool);
    error InvalidBins();
    error InvalidAmounts();
    error InsufficientShares(int256 bin, uint256 actual, uint256 minimum);
    error InsufficientOutput(uint256 amount0, uint256 amount1);

    event MetricLiquidityAdded(
        address indexed sickle,
        address indexed pool,
        uint80 indexed salt,
        int256[] bins,
        uint256[] shares,
        uint256 amount0,
        uint256 amount1
    );
    event MetricLiquidityRemoved(
        address indexed sickle,
        address indexed pool,
        uint80 indexed salt,
        int256[] bins,
        uint256[] shares,
        uint256 amount0,
        uint256 amount1
    );

    IMetricOmmFactory public immutable override metricFactory;
    IMetricOmmLiquidityAdder public immutable liquidityAdder;
    IMetricOmmDataProvider public immutable dataProvider;
    address private immutable self;

    constructor(
        IMetricOmmFactory factory_,
        IMetricOmmLiquidityAdder adder_,
        IMetricOmmDataProvider provider_
    ) {
        if (
            address(factory_).code.length == 0
                || address(adder_).code.length == 0
                || address(provider_).code.length == 0
        ) revert InvalidDependency();
        metricFactory = factory_;
        liquidityAdder = adder_;
        dataProvider = provider_;
        self = address(this);
    }

    modifier delegated() {
        if (address(this) == self) revert OnlyDelegateCall();
        _;
    }

    function poolInfo(
        address pool
    ) public view override returns (MetricPoolImmutables memory info) {
        if (!metricFactory.isPool(pool)) revert InvalidPool(pool);
        info = IMetricOmmPool(pool).getImmutables();
        if (
            info.factory != address(metricFactory) || info.token0 == address(0)
                || info.token1 == address(0) || info.token0 == info.token1
                || info.token0ScaleMultiplier == 0
                || info.token1ScaleMultiplier == 0
        ) revert InvalidPool(pool);
    }

    function positionShares(
        MetricPosition calldata position,
        address owner,
        int256[] calldata bins
    ) external view override returns (uint256[] memory) {
        MetricPoolImmutables memory info = poolInfo(position.pool);
        _checkBins(info, bins);
        return _shares(position, owner, bins);
    }

    function underlyingAmounts(
        MetricPosition calldata position,
        address owner,
        int256[] calldata bins
    ) external view override returns (uint256 amount0, uint256 amount1) {
        MetricPoolImmutables memory info = poolInfo(position.pool);
        _checkBins(info, bins);
        for (uint256 i; i < bins.length; ++i) {
            int16 bin = int16(bins[i]);
            uint256 shares = dataProvider.positionBinShares(
                position.pool, owner, position.salt, bin
            );
            if (shares == 0) continue;
            uint256 total = dataProvider.binTotalShares(position.pool, bin);
            (uint104 reserve0, uint104 reserve1,,,) =
                dataProvider.binState(position.pool, bin);
            amount0 += Math.mulDiv(shares, reserve0, total);
            amount1 += Math.mulDiv(shares, reserve1, total);
        }
        // Match core's per-bin floor followed by one native-unit conversion.
        amount0 /= info.token0ScaleMultiplier;
        amount1 /= info.token1ScaleMultiplier;
    }

    function addLiquidity(
        MetricAddLiquidity calldata params
    ) external payable override delegated {
        MetricPoolImmutables memory info = poolInfo(params.position.pool);
        _checkBins(info, params.weights.binIdxs);
        uint256 n = params.weights.binIdxs.length;
        if (params.weights.shares.length != n || params.minShares.length != n) {
            revert InvalidAmounts();
        }
        for (uint256 i; i < n; ++i) {
            if (params.weights.shares[i] == 0) revert InvalidAmounts();
        }
        AddState memory state;
        state.balance0 = IERC20(info.token0).balanceOf(address(this));
        state.balance1 = IERC20(info.token1).balanceOf(address(this));
        state.cap0 = Math.min(params.amount0Max, state.balance0);
        state.cap1 = Math.min(params.amount1Max, state.balance1);
        if (state.cap0 == 0 && state.cap1 == 0) revert InvalidAmounts();
        state.beforeShares =
            _shares(params.position, address(this), params.weights.binIdxs);
        _approve(info.token0, state.cap0);
        _approve(info.token1, state.cap1);
        _add(params, state.cap0, state.cap1);
        _approve(info.token0, 0);
        _approve(info.token1, 0);
        uint256 spent0 =
            state.balance0 - IERC20(info.token0).balanceOf(address(this));
        uint256 spent1 =
            state.balance1 - IERC20(info.token1).balanceOf(address(this));
        if (spent0 > state.cap0 || spent1 > state.cap1) {
            revert InvalidAmounts();
        }
        uint256[] memory minted =
            _shares(params.position, address(this), params.weights.binIdxs);
        for (uint256 i; i < n; ++i) {
            minted[i] -= state.beforeShares[i];
            if (minted[i] == 0 || minted[i] < params.minShares[i]) {
                revert InsufficientShares(
                    params.weights.binIdxs[i], minted[i], params.minShares[i]
                );
            }
        }
        emit MetricLiquidityAdded(
            address(this),
            params.position.pool,
            params.position.salt,
            params.weights.binIdxs,
            minted,
            spent0,
            spent1
        );
    }

    function _add(
        MetricAddLiquidity calldata params,
        uint256 cap0,
        uint256 cap1
    ) private {
        liquidityAdder.addLiquidityWeighted(
            params.position.pool,
            address(this),
            params.position.salt,
            params.weights,
            cap0,
            cap1,
            params.bounds,
            params.extensionData
        );
    }

    function removeLiquidity(
        MetricRemoveLiquidity calldata params
    ) external payable override delegated {
        MetricPoolImmutables memory info = poolInfo(params.position.pool);
        _checkBins(info, params.deltas.binIdxs);
        uint256 n = params.deltas.binIdxs.length;
        if (params.deltas.shares.length != n) revert InvalidAmounts();
        uint256[] memory held =
            _shares(params.position, address(this), params.deltas.binIdxs);
        uint256[] memory burns = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 requested = params.deltas.shares[i];
            burns[i] = requested == type(uint256).max ? held[i] : requested;
            if (burns[i] == 0 || burns[i] > held[i]) revert InvalidAmounts();
        }
        uint256 before0 = IERC20(info.token0).balanceOf(address(this));
        uint256 before1 = IERC20(info.token1).balanceOf(address(this));
        IMetricOmmPool(params.position.pool)
            .removeLiquidity(
                address(this),
                params.position.salt,
                MetricLiquidityDelta(params.deltas.binIdxs, burns),
                params.extensionData
            );
        uint256 amount0 = IERC20(info.token0).balanceOf(address(this)) - before0;
        uint256 amount1 = IERC20(info.token1).balanceOf(address(this)) - before1;
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert InsufficientOutput(amount0, amount1);
        }
        uint256[] memory remaining =
            _shares(params.position, address(this), params.deltas.binIdxs);
        for (uint256 i; i < n; ++i) {
            if (held[i] - remaining[i] != burns[i]) revert InvalidAmounts();
        }
        emit MetricLiquidityRemoved(
            address(this),
            params.position.pool,
            params.position.salt,
            params.deltas.binIdxs,
            burns,
            amount0,
            amount1
        );
    }

    function _shares(
        MetricPosition calldata position,
        address owner,
        int256[] calldata bins
    ) private view returns (uint256[] memory shares) {
        shares = new uint256[](bins.length);
        for (uint256 i; i < bins.length; ++i) {
            shares[i] = dataProvider.positionBinShares(
                position.pool, owner, position.salt, int16(bins[i])
            );
        }
    }

    function _checkBins(
        MetricPoolImmutables memory info,
        int256[] calldata bins
    ) private pure {
        if (bins.length == 0) revert InvalidBins();
        for (uint256 i; i < bins.length; ++i) {
            if (
                bins[i] < info.lowestBin || bins[i] > info.highestBin
                    || bins[i] < type(int16).min || bins[i] > type(int16).max
                    || (i > 0 && bins[i] <= bins[i - 1])
            ) revert InvalidBins();
        }
    }

    function _approve(
        address token,
        uint256 amount
    ) private {
        SafeTransferLib.safeApprove(token, address(liquidityAdder), 0);
        if (amount != 0) {
            SafeTransferLib.safeApprove(token, address(liquidityAdder), amount);
        }
    }
}
