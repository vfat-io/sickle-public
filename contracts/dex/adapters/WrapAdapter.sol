// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import { IWETH9 as IWETH } from "contracts/interfaces/external/IWETH.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";

/// @title WrapAdapter
/// @notice Handles both `DexType.WrapWETH` (native → WETH) and
/// `DexType.UnwrapWETH` (WETH → native). `SwapRouter` invokes WETH
/// directly via `adapterCall`, so the deposit / withdraw is credited /
/// debited against the router's own balance — no ETH or WETH ever
/// transits this adapter.
contract WrapAdapter is DexAdapterBase {
    error InvalidWrappedNative();

    address public immutable wrappedNative;

    constructor(
        address admin_,
        address allowlist_,
        address wrappedNative_
    ) DexAdapterBase(admin_, allowlist_) {
        if (wrappedNative_ == address(0)) revert InvalidAddress();
        wrappedNative = wrappedNative_;
    }

    function version() external pure override returns (uint16) {
        return 1;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256) {
        uint8 dexType = step.dexType;
        if (dexType == uint8(DexType.WrapWETH)) {
            if (step.tokenIn != address(0) || step.tokenOut != wrappedNative) {
                revert InvalidWrappedNative();
            }
            _adapterCall(
                wrappedNative, amountIn, abi.encodeCall(IWETH.deposit, ())
            );
            return amountIn;
        }
        if (dexType == uint8(DexType.UnwrapWETH)) {
            if (step.tokenIn != wrappedNative || step.tokenOut != address(0)) {
                revert InvalidWrappedNative();
            }
            _adapterCall(
                wrappedNative, 0, abi.encodeCall(IWETH.withdraw, (amountIn))
            );
            return amountIn;
        }
        revert InvalidWrappedNative();
    }
}
