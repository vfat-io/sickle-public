// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/interfaces/ILiquidityConnector.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    IAllowanceTransfer
} from "contracts/interfaces/external/IAllowanceTransfer.sol";
import {
    Permit2AllowanceLib
} from "contracts/libraries/Permit2AllowanceLib.sol";
import {
    IBalancerV3Router
} from "contracts/interfaces/external/balancer/v3/IBalancerV3Router.sol";
import {
    IBalancerV3Vault,
    BalancerV3TokenInfo
} from "contracts/interfaces/external/balancer/v3/IBalancerV3Vault.sol";
import {
    IBalancerV3Pool,
    BalancerV3PoolSwapParams
} from "contracts/interfaces/external/balancer/v3/IBalancerV3Pool.sol";

/// @notice `Proportional` mints the most BPT the desired amounts cover at the
/// pool's ratio (no swap fee, no invariant cap; the excess stays in the
/// Sickle). `Unbalanced` adds every desired amount exactly, paying the swap fee
/// on the non-proportional part.
enum BalancerV3AddKind {
    Proportional,
    Unbalanced
}

/// @notice `Proportional` returns every pool token pro rata.
/// `SingleTokenExactIn` returns everything in `tokens[tokenOutIndex]`.
enum BalancerV3RemoveKind {
    Proportional,
    SingleTokenExactIn
}

struct BalancerV3AddLiquidityExtraData {
    BalancerV3AddKind kind;
    uint256 minBptAmountOut;
}

struct BalancerV3RemoveLiquidityExtraData {
    BalancerV3RemoveKind kind;
    uint256 tokenOutIndex;
}

/// @title BalancerV3Connector
/// @notice Liquidity connector for a Balancer V3 Vault, registered against the
/// Vault's Permit2 `Router`. `lpToken` is the pool, which is also the BPT.
/// `tokens` must be in the pool's registration order, which indexes every
/// amount array. The Router pulls inputs through Permit2, so each add grants
/// `token -> Permit2 -> router` for exactly the desired amount and revokes it
/// afterwards.
///
/// It is also the `IFarmConnector` of an unstaked position (resolved for the
/// pool by `BalancerV3PoolRegistry`, as `CurvePoolConnector` is for Curve):
/// the BPT stays in the Sickle, so the mutators are no-ops.
contract BalancerV3Connector is ILiquidityConnector, IFarmConnector {
    error InvalidRouter();
    error InvalidPoolTokens();
    error InvalidAmounts();
    error InvalidTokenIndex();
    error InsufficientBptOut(uint256 bptAmountOut, uint256 minBptAmountOut);
    error PoolMismatch(address stakingContract, address lpToken);

    uint256 internal constant ONE = 1e18;
    uint256 internal constant PROBE_DIVISOR = 1e6;

    IBalancerV3Vault public immutable VAULT;
    address public immutable PERMIT2;

    constructor(
        IBalancerV3Vault vault_,
        address permit2_
    ) {
        VAULT = vault_;
        PERMIT2 = permit2_;
    }

    function addLiquidity(
        AddLiquidityParams memory params
    ) external override {
        IBalancerV3Router router = _checkRouter(params.router);
        _checkTokens(params.lpToken, params.tokens);
        uint256 n = params.tokens.length;
        if (params.desiredAmounts.length != n) revert InvalidAmounts();

        BalancerV3AddLiquidityExtraData memory extra;
        if (params.extraData.length > 0) {
            extra = abi.decode(
                params.extraData, (BalancerV3AddLiquidityExtraData)
            );
        }

        for (uint256 i; i < n; i++) {
            _approvePermit2(
                params.tokens[i], address(router), params.desiredAmounts[i]
            );
        }

        if (extra.kind == BalancerV3AddKind.Proportional) {
            uint256 bptAmountOut =
                _proportionalBptOut(params.lpToken, params.desiredAmounts);
            if (bptAmountOut == 0 || bptAmountOut < extra.minBptAmountOut) {
                revert InsufficientBptOut(bptAmountOut, extra.minBptAmountOut);
            }
            router.addLiquidityProportional(
                params.lpToken, params.desiredAmounts, bptAmountOut, false, ""
            );
        } else {
            router.addLiquidityUnbalanced(
                params.lpToken,
                params.desiredAmounts,
                extra.minBptAmountOut,
                false,
                ""
            );
        }

        for (uint256 i; i < n; i++) {
            _revokePermit2(params.tokens[i], address(router));
        }
    }

    function removeLiquidity(
        RemoveLiquidityParams memory params
    ) external override {
        IBalancerV3Router router = _checkRouter(params.router);
        _checkTokens(params.lpToken, params.tokens);
        if (params.minAmountsOut.length != params.tokens.length) {
            revert InvalidAmounts();
        }
        if (params.lpAmountIn == 0) revert InvalidAmounts();

        BalancerV3RemoveLiquidityExtraData memory extra;
        if (params.extraData.length > 0) {
            extra = abi.decode(
                params.extraData, (BalancerV3RemoveLiquidityExtraData)
            );
        }

        if (extra.kind == BalancerV3RemoveKind.Proportional) {
            router.removeLiquidityProportional(
                params.lpToken,
                params.lpAmountIn,
                params.minAmountsOut,
                false,
                ""
            );
        } else {
            if (extra.tokenOutIndex >= params.tokens.length) {
                revert InvalidTokenIndex();
            }
            router.removeLiquiditySingleTokenExactIn(
                params.lpToken,
                params.lpAmountIn,
                params.tokens[extra.tokenOutIndex],
                params.minAmountsOut[extra.tokenOutIndex],
                false,
                ""
            );
        }
    }

    /// @dev Fee-free spot price in live (rate-scaled) balances: exact for
    /// weighted pools, otherwise the pool's own `onSwap` for a trade of
    /// `balanceBase / PROBE_DIVISOR`.
    function getPoolPrice(
        address lpToken,
        uint256 baseTokenIndex,
        uint256 quoteTokenIndex
    ) external view override returns (uint256 price) {
        uint256[] memory balances = VAULT.getCurrentLiveBalances(lpToken);
        if (
            baseTokenIndex >= balances.length
                || quoteTokenIndex >= balances.length
                || baseTokenIndex == quoteTokenIndex
        ) revert InvalidTokenIndex();
        uint256 balanceBase = balances[baseTokenIndex];
        uint256 balanceQuote = balances[quoteTokenIndex];
        if (balanceBase == 0 || balanceQuote == 0) revert InvalidPrice();

        (bool ok, bytes memory data) = lpToken.staticcall(
            abi.encodeCall(IBalancerV3Pool.getNormalizedWeights, ())
        );
        if (ok && data.length >= 64) {
            uint256[] memory weights = abi.decode(data, (uint256[]));
            if (weights.length != balances.length) revert InvalidPrice();
            price = (balanceQuote * weights[baseTokenIndex] * ONE)
                / (balanceBase * weights[quoteTokenIndex]);
        } else {
            uint256 probe = balanceBase / PROBE_DIVISOR;
            if (probe == 0) revert InvalidPrice();
            uint256 out = IBalancerV3Pool(lpToken)
                .onSwap(
                    BalancerV3PoolSwapParams({
                    kind: 0,
                    amountGivenScaled18: probe,
                    balancesScaled18: balances,
                    indexIn: baseTokenIndex,
                    indexOut: quoteTokenIndex,
                    router: address(0),
                    userData: ""
                })
                );
            price = (out * ONE) / probe;
        }
        if (price == 0) revert InvalidPrice();
    }

    function getReserves(
        address lpToken
    ) external view override returns (uint256[] memory reserves) {
        (,, reserves,) = VAULT.getPoolTokenInfo(lpToken);
    }

    function getTokens(
        address lpToken
    ) external view override returns (address[] memory tokens) {
        return VAULT.getPoolTokens(lpToken);
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

    /// @dev A no-op, not a revert, so harvest-then-withdraw exits still work.
    function claim(
        Farm calldata,
        bytes memory
    ) external pure override { }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        return IERC20(farm.stakingContract).balanceOf(user);
    }

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

    function _checkRouter(
        address router
    ) internal view returns (IBalancerV3Router) {
        if (
            router == address(0)
                || IBalancerV3Router(router).getVault() != address(VAULT)
                || IBalancerV3Router(router).getPermit2() != PERMIT2
        ) revert InvalidRouter();
        return IBalancerV3Router(router);
    }

    function _checkTokens(
        address pool,
        address[] memory tokens
    ) internal view {
        address[] memory poolTokens = VAULT.getPoolTokens(pool);
        if (poolTokens.length != tokens.length) revert InvalidPoolTokens();
        for (uint256 i; i < tokens.length; i++) {
            if (poolTokens[i] != tokens[i]) revert InvalidPoolTokens();
        }
    }

    /// @dev Largest `bptOut` whose proportional cost fits every desired
    /// amount. The Vault rounds the cost up twice (scaled-18, then raw), which
    /// can cost one raw unit more than the raw ratio; `desired - 1` absorbs it.
    function _proportionalBptOut(
        address pool,
        uint256[] memory desiredAmounts
    ) internal view returns (uint256 bptOut) {
        (,, uint256[] memory balancesRaw,) = VAULT.getPoolTokenInfo(pool);
        uint256 totalSupply = VAULT.totalSupply(pool);
        bptOut = type(uint256).max;
        for (uint256 i; i < balancesRaw.length; i++) {
            if (desiredAmounts[i] <= 1 || balancesRaw[i] == 0) return 0;
            uint256 candidate =
                ((desiredAmounts[i] - 1) * totalSupply) / balancesRaw[i];
            if (candidate < bptOut) bptOut = candidate;
        }
    }

    function _approvePermit2(
        address token,
        address router,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        if (amount > type(uint160).max) revert InvalidAmounts();
        if (!Permit2AllowanceLib.hasFixedAllowance(
                token, address(this), PERMIT2
            )) {
            SafeTransferLib.safeApprove(token, PERMIT2, 0);
            SafeTransferLib.safeApprove(token, PERMIT2, amount);
        }
        IAllowanceTransfer(PERMIT2)
            .approve(token, router, uint160(amount), uint48(block.timestamp));
    }

    function _revokePermit2(
        address token,
        address router
    ) internal {
        IAllowanceTransfer(PERMIT2).approve(token, router, 0, 0);
        if (!Permit2AllowanceLib.hasFixedAllowance(
                token, address(this), PERMIT2
            )) {
            SafeTransferLib.safeApprove(token, PERMIT2, 0);
        }
    }
}
