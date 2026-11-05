// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IBalancerV3AggregatorRouter
} from "contracts/interfaces/external/balancer/v3/IBalancerV3AggregatorRouter.sol";
import {
    IBalancerV3Vault,
    BalancerV3HooksConfig
} from "contracts/interfaces/external/balancer/v3/IBalancerV3Vault.sol";
import {
    IBalancerV3PoolFactory
} from "contracts/interfaces/external/balancer/v3/IBalancerV3PoolFactory.sol";

/// @title BushAggregatorRouterAdapter
/// @notice Adapter for `DexType.BushAggregatorRouter`: a single-pool exact-in
/// swap through Bush's (Balancer V3) prepaid `AggregatorRouter`.
/// `step.dexData` is `abi.encode(pool, factory)`. Balancer V3 pools do not
/// expose their factory, so the caller names it and the adapter proves it:
/// the factory must be allow-listed, bound to `VAULT`, and vouch for the pool,
/// and a pool hook must be allow-listed. The input is prepaid to the Vault,
/// and the router sends the output to `SwapRouter` (`msg.sender`), whose
/// balance-delta, `minAmountOut` and deadline checks are authoritative.
contract BushAggregatorRouterAdapter is DexAdapterBase {
    error InvalidDexType();
    error InvalidDexData();
    error InvalidRouter();
    error VaultMismatch();
    error InvalidPool();
    error InvalidTokenIn();
    error InvalidTokenOut();

    address public immutable AGGREGATOR_ROUTER;
    address public immutable VAULT;

    constructor(
        address admin_,
        address allowlist_,
        address aggregatorRouter_,
        address vault_
    ) DexAdapterBase(admin_, allowlist_) {
        if (aggregatorRouter_ == address(0) || vault_ == address(0)) {
            revert InvalidAddress();
        }
        if (IBalancerV3AggregatorRouter(aggregatorRouter_).getVault() != vault_)
        {
            revert VaultMismatch();
        }
        AGGREGATOR_ROUTER = aggregatorRouter_;
        VAULT = vault_;
    }

    function version() external pure override returns (uint16) {
        return 1;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256) {
        if (step.dexType != uint8(DexType.BushAggregatorRouter)) {
            revert InvalidDexType();
        }
        if (step.router != AGGREGATOR_ROUTER) revert InvalidRouter();
        if (step.dexData.length != 64) revert InvalidDexData();
        (address pool, address factory) =
            abi.decode(step.dexData, (address, address));

        // The input is prepaid, so the pool is proven before it moves.
        _validatePool(pool, factory, step.tokenIn, step.tokenOut);

        _adapterPullTo(step.tokenIn, amountIn, VAULT);
        bytes memory result = _adapterCall(
            AGGREGATOR_ROUTER,
            0,
            abi.encodeCall(
                IBalancerV3AggregatorRouter.swapSingleTokenExactIn,
                (
                    pool,
                    step.tokenIn,
                    step.tokenOut,
                    amountIn,
                    0,
                    block.timestamp,
                    ""
                )
            )
        );

        return abi.decode(result, (uint256));
    }

    function _validatePool(
        address pool,
        address factory,
        address tokenIn,
        address tokenOut
    ) internal view {
        allowlist.requireAllowedFactory(factory);
        if (IBalancerV3PoolFactory(factory).getVault() != VAULT) {
            revert VaultMismatch();
        }
        if (!IBalancerV3PoolFactory(factory).isPoolFromFactory(pool)) {
            revert InvalidPool();
        }

        address hooksContract =
            IBalancerV3Vault(VAULT).getHooksConfig(pool).hooksContract;
        if (hooksContract != address(0)) {
            allowlist.requireAllowedHook(hooksContract);
        }

        address[] memory tokens = IBalancerV3Vault(VAULT).getPoolTokens(pool);
        bool hasIn;
        bool hasOut;
        for (uint256 i; i < tokens.length; i++) {
            if (tokens[i] == tokenIn) hasIn = true;
            else if (tokens[i] == tokenOut) hasOut = true;
        }
        if (!hasIn) revert InvalidTokenIn();
        if (!hasOut) revert InvalidTokenOut();
    }
}
