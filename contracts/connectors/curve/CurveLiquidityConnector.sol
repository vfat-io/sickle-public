// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/interfaces/ILiquidityConnector.sol";
import {
    ICurveMetaRegistry,
    ICurveLiquidityResolver,
    CurveLiquidityPool,
    CurveLiquidityKind
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    CurveAddLiquidityExtraData,
    IERC20Decimals
} from "contracts/connectors/curve/CurvePoolConnector.sol";
import { WETH } from "solmate/tokens/WETH.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

/// @notice Direct-coin liquidity for supported Curve source families. Metapools
/// use their base LP coin; expanded underlying-coin deposit zaps are separate
/// routers and are intentionally rejected. ETH coins are exposed as WETH.
/// @dev All state used during Sickle delegatecall lives in immutable contracts.
/// Each operation resolves the pool once and reads its coins at most once.
abstract contract CurveLiquidityConnector is
    ILiquidityConnector,
    IFarmConnector
{
    error InvalidLiquidityParams();
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    ICurveLiquidityResolver public immutable resolver;
    ICurveMetaRegistry public immutable metaRegistry;
    WETH public immutable weth;

    constructor(
        ICurveLiquidityResolver resolver_,
        address weth_
    ) {
        resolver = resolver_;
        metaRegistry = resolver_.metaRegistry();
        weth = WETH(payable(weth_));
    }

    function addLiquidity(
        AddLiquidityParams memory params
    ) external override {
        (CurveLiquidityPool memory info, address[8] memory coins) = _validate(
            params.router,
            params.lpToken,
            params.tokens,
            params.desiredAmounts.length
        );
        uint256 minimum =
            abi.decode(params.extraData, (CurveAddLiquidityExtraData))
        .minMintAmount;
        uint256 value;
        for (uint256 i; i < info.nCoins; i++) {
            if (coins[i] == ETH) value += params.desiredAmounts[i];
        }
        if (value != 0) weth.withdraw(value);
        _addLiquidity(info, params.desiredAmounts, minimum, value);
    }

    function removeLiquidity(
        RemoveLiquidityParams memory params
    ) external override {
        (CurveLiquidityPool memory info,) = _validate(
            params.router,
            params.lpToken,
            params.tokens,
            params.minAmountsOut.length
        );
        uint256 before = address(this).balance;
        _removeLiquidity(info, params.lpAmountIn, params.minAmountsOut);
        // Curve burns the caller's LP without consuming ZapLib's approval.
        SafeTransferLib.safeApprove(info.lpToken, info.pool, 0);
        uint256 received = address(this).balance - before;
        if (received != 0) weth.deposit{ value: received }();
    }

    function _validate(
        address router,
        address lp,
        address[] memory tokens,
        uint256 length
    )
        internal
        view
        returns (CurveLiquidityPool memory info, address[8] memory coins)
    {
        (info, coins) = _resolve(router);
        if (
            info.pool != router || info.lpToken != lp
                || tokens.length != info.nCoins || length != info.nCoins
        ) revert InvalidLiquidityParams();
        for (uint256 i; i < tokens.length; i++) {
            if (tokens[i] != _token(coins[i])) revert InvalidLiquidityParams();
        }
    }

    function _resolve(
        address poolOrLp
    )
        internal
        view
        returns (CurveLiquidityPool memory info, address[8] memory coins)
    {
        info = _poolInfo(poolOrLp);
        coins = _coins(info);
    }

    function _poolInfo(
        address target
    ) internal view returns (CurveLiquidityPool memory info) {
        info = resolver.poolInfo(target);
        if (info.kind != poolKind()) revert InvalidLiquidityParams();
    }

    function poolKind() public pure virtual returns (CurveLiquidityKind);

    function _addLiquidity(
        CurveLiquidityPool memory info,
        uint256[] memory amounts,
        uint256 minimum,
        uint256 value
    ) internal virtual;
    function _removeLiquidity(
        CurveLiquidityPool memory info,
        uint256 amount,
        uint256[] memory minimums
    ) internal virtual;

    function _token(
        address coin
    ) internal view returns (address) {
        return coin == ETH ? address(weth) : coin;
    }

    function getTokens(
        address lp
    ) external view override returns (address[] memory tokens) {
        (CurveLiquidityPool memory info, address[8] memory coins) = _resolve(lp);
        tokens = new address[](info.nCoins);
        for (uint256 i; i < tokens.length; i++) {
            tokens[i] = _token(coins[i]);
        }
    }

    function getReserves(
        address lp
    ) external view override returns (uint256[] memory reserves) {
        CurveLiquidityPool memory info = _poolInfo(lp);
        uint256[8] memory balances = _balances(info);
        reserves = new uint256[](info.nCoins);
        for (uint256 i; i < reserves.length; i++) {
            reserves[i] = balances[i];
        }
    }

    function getPoolPrice(
        address lp,
        uint256 baseIndex,
        uint256 quoteIndex
    ) external view override returns (uint256 price) {
        (CurveLiquidityPool memory info, address[8] memory coins) = _resolve(lp);
        if (
            baseIndex >= info.nCoins || quoteIndex >= info.nCoins
                || baseIndex == quoteIndex
        ) revert InvalidPrice();
        uint256 baseDecimals =
            IERC20Decimals(_token(coins[baseIndex])).decimals();
        uint256 quoteDecimals =
            IERC20Decimals(_token(coins[quoteIndex])).decimals();
        uint256 out = _dy(info, baseIndex, quoteIndex, 10 ** baseDecimals);
        if (out != 0) {
            price = out * 1e18 / 10 ** quoteDecimals;
        } else {
            out = _dy(info, quoteIndex, baseIndex, 10 ** quoteDecimals);
            if (out == 0) revert InvalidPrice();
            price = 1e18 * 10 ** baseDecimals / out;
        }
        if (price == 0) revert InvalidPrice();
    }

    function _coins(
        CurveLiquidityPool memory info
    ) internal view virtual returns (address[8] memory) {
        return resolver.metaRegistryForPool(info.pool).get_coins(info.pool);
    }

    function _balances(
        CurveLiquidityPool memory info
    ) internal view virtual returns (uint256[8] memory) {
        return resolver.metaRegistryForPool(info.pool).get_balances(info.pool);
    }

    function _dy(
        CurveLiquidityPool memory info,
        uint256 i,
        uint256 j,
        uint256 amount
    ) internal view virtual returns (uint256);

    function deposit(
        Farm calldata farm,
        address token,
        bytes memory
    ) external view override {
        CurveLiquidityPool memory info = _poolInfo(farm.stakingContract);
        if (info.lpToken != token) {
            revert InvalidLiquidityParams();
        }
    }

    function withdraw(
        Farm calldata,
        uint256,
        bytes memory
    ) external pure override { }
    function claim(
        Farm calldata,
        bytes memory
    ) external pure override { }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        CurveLiquidityPool memory info = _poolInfo(farm.stakingContract);
        return IERC20(info.lpToken).balanceOf(user);
    }

    function earned(
        Farm calldata,
        address,
        address[] calldata tokens
    ) external pure override returns (uint256[] memory) {
        return new uint256[](tokens.length);
    }

    function isStaked(
        Farm calldata,
        address
    ) external pure override returns (bool) {
        return false;
    }
}
