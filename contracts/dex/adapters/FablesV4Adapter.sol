// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IAllowanceTransfer
} from "contracts/interfaces/external/IAllowanceTransfer.sol";
import {
    IUniversalRouter
} from "contracts/interfaces/external/uniswap/v4/IUniversalRouter.sol";
import {
    Actions
} from "contracts/interfaces/external/uniswap/v4/libraries/Actions.sol";
import {
    IV4Router
} from "contracts/interfaces/external/uniswap/v4/IV4Router.sol";
import {
    Permit2AllowanceLib
} from "contracts/libraries/Permit2AllowanceLib.sol";
import {
    PoolKey
} from "contracts/interfaces/external/uniswap/v4/types/PoolKey.sol";
import {
    PoolId
} from "contracts/interfaces/external/uniswap/v4/types/PoolId.sol";
import { IHooks } from "contracts/interfaces/external/uniswap/v4/IHooks.sol";
import {
    Currency
} from "contracts/interfaces/external/uniswap/v4/types/Currency.sol";
import {
    IFablesPoolRegistry
} from "contracts/interfaces/external/fables/IFablesPoolRegistry.sol";

/// @title FablesV4Adapter
/// @notice Robinhood's isolated Uniswap V4 adapter for Fables registry-backed
/// hooks. The generic V4 adapter still requires every non-zero hook to be in
/// `RouterAllowlist`; this adapter only adds an exact-active-pool fallback for
/// the immutable Fables registry supplied at deployment.
/// @dev This is intentionally a local copy of `UniswapV4Adapter`: changing
/// the generic artifact would alter its deployed-bytecode replacement graph on
/// every V4 chain. Keep the Permit2 and router-call sequence in lock-step.
contract FablesV4Adapter is DexAdapterBase {
    uint8 internal constant V4_SWAP = 0x10;

    address public constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice The sole Fables registry trusted for the fallback hook path.
    IFablesPoolRegistry public immutable fablesPoolRegistry;

    error InvalidFablesPoolRegistry(address registry);

    constructor(
        address admin_,
        address allowlist_,
        IFablesPoolRegistry fablesPoolRegistry_
    ) DexAdapterBase(admin_, allowlist_) {
        if (address(fablesPoolRegistry_).code.length == 0) {
            revert InvalidFablesPoolRegistry(address(fablesPoolRegistry_));
        }
        fablesPoolRegistry = fablesPoolRegistry_;
    }

    /// @notice Version distinct from generic V4 adapter version 1.
    function version() external pure override returns (uint16) {
        return 2;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256) {
        PoolKey memory poolKey = abi.decode(step.dexData, (PoolKey));
        PoolKey memory executedPoolKey = _executedPoolKey(step, poolKey);
        if (executedPoolKey.hooks != IHooks(address(0))) {
            _requireAllowedHook(executedPoolKey);
        }

        bool hasFixedPermit2Allowance;
        if (step.tokenIn != address(0)) {
            hasFixedPermit2Allowance = Permit2AllowanceLib.hasFixedAllowance(
                step.tokenIn, msg.sender, PERMIT2
            );
            if (!hasFixedPermit2Allowance) {
                _adapterApprove(step.tokenIn, PERMIT2, amountIn);
            }
            _adapterCall(
                PERMIT2,
                0,
                abi.encodeCall(
                    IAllowanceTransfer.approve,
                    (
                        step.tokenIn,
                        step.router,
                        // forge-lint: disable-next-line(unsafe-typecast)
                        uint160(amountIn),
                        uint48(block.timestamp)
                    )
                )
            );
        }

        {
            bytes memory input = _buildV4Input(step, executedPoolKey, amountIn);
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = input;

            uint256 value = step.tokenIn == address(0) ? amountIn : 0;
            _adapterCall(
                step.router,
                value,
                abi.encodeCall(
                    IUniversalRouter.execute,
                    (abi.encodePacked(V4_SWAP), inputs, block.timestamp)
                )
            );
        }

        if (step.tokenIn != address(0)) {
            if (!hasFixedPermit2Allowance) {
                _adapterApprove(step.tokenIn, PERMIT2, 0);
            }
            _adapterCall(
                PERMIT2,
                0,
                abi.encodeCall(
                    IAllowanceTransfer.approve,
                    (step.tokenIn, step.router, 0, 0)
                )
            );
        }
        return 0;
    }

    /// @notice Whether `poolKey` exactly matches an active entry in the
    /// immutable Fables registry. This is intentionally stronger than a hook
    /// membership check: the currencies, fee, tick spacing, hook, and stored
    /// PoolId must all match `poolById(poolKey.toId())`.
    function isActiveFablesPool(
        PoolKey calldata poolKey
    ) external view returns (bool) {
        PoolKey memory key = poolKey;
        return _isActiveFablesPool(key);
    }

    function _requireAllowedHook(
        PoolKey memory poolKey
    ) internal view {
        address hook = address(poolKey.hooks);

        // Preserve the normal allowlist path for hooks explicitly approved by
        // governance. Calling requireAllowedHook keeps this path semantically
        // identical to UniswapV4Adapter.
        if (allowlist.isAllowedHook(hook)) {
            allowlist.requireAllowedHook(hook);
            return;
        }

        if (!_isActiveFablesPool(poolKey)) {
            // Reuse the generic adapter's fail-closed error surface.
            allowlist.requireAllowedHook(hook);
        }
    }

    function _isActiveFablesPool(
        PoolKey memory poolKey
    ) internal view returns (bool) {
        PoolId poolId = poolKey.toId();
        IFablesPoolRegistry.PoolInfo memory info =
            fablesPoolRegistry.poolById(poolId);

        return info.active && PoolId.unwrap(info.id) == PoolId.unwrap(poolId)
            && _samePoolKey(poolKey, info.key);
    }

    function _samePoolKey(
        PoolKey memory a,
        PoolKey memory b
    ) private pure returns (bool) {
        return Currency.unwrap(a.currency0) == Currency.unwrap(b.currency0)
            && Currency.unwrap(a.currency1) == Currency.unwrap(b.currency1)
            && a.fee == b.fee && a.tickSpacing == b.tickSpacing
            && address(a.hooks) == address(b.hooks);
    }

    /// @dev Constructs the exact key passed to UniversalRouter. The route
    /// tokens, rather than the untrusted serialized currencies in `dexData`,
    /// determine the two currencies UniversalRouter will execute against.
    function _executedPoolKey(
        SwapStep calldata step,
        PoolKey memory poolKey
    ) private pure returns (PoolKey memory) {
        (address currency0, address currency1) = step.tokenIn < step.tokenOut
            ? (step.tokenIn, step.tokenOut)
            : (step.tokenOut, step.tokenIn);

        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: poolKey.fee,
            hooks: poolKey.hooks,
            tickSpacing: poolKey.tickSpacing
        });
    }

    function _buildV4Input(
        SwapStep calldata step,
        PoolKey memory poolKey,
        uint256 amountIn
    ) internal pure returns (bytes memory) {
        bool zeroForOne = step.tokenIn == Currency.unwrap(poolKey.currency0);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);

        IV4Router.ExactInputSingleParams memory swapParams =
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: new bytes(0)
            });
        params[0] = abi.encode(swapParams);
        params[1] = abi.encode(step.tokenIn, amountIn);
        params[2] = abi.encode(step.tokenOut, 0);

        return abi.encode(actions, params);
    }
}
