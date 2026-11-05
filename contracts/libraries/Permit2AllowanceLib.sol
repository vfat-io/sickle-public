// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    IERC20Minimal
} from "contracts/interfaces/external/uniswap/v4/IERC20Minimal.sol";

/// @title Permit2AllowanceLib
/// @notice Detects ERC20s whose Permit2 allowance is hardcoded to
/// `type(uint256).max`.
/// @dev Solady's ERC20 enables `_givePermit2InfiniteAllowance()` by default:
/// `allowance(anyone, PERMIT2)` always reads `type(uint256).max`, and
/// `approve(PERMIT2, x)` reverts with `Permit2AllowanceIsFixedAtInfinity()`
/// for every `x != type(uint256).max`. The usual approve-to-zero-then-approve
/// reset dance therefore reverts on *both* legs, so callers must skip the
/// ERC20 approval entirely — the allowance is already infinite — and go
/// straight to the `IAllowanceTransfer.approve` step.
library Permit2AllowanceLib {
    /// @notice Whether the ERC20 approve/revoke against `permit2` has to be
    /// skipped for `token`.
    /// @param token ERC20 to probe.
    /// @param owner Account whose balance Permit2 pulls from. For connectors
    /// this is `address(this)`: they run under `DELEGATECALL` from the Sickle,
    /// so the Sickle is the approver. For DEX adapters it is the `SwapRouter`,
    /// which holds custody and issues the approval on the adapter's behalf.
    /// @param permit2 Permit2 deployment the token would hardcode against —
    /// Uniswap and Pancake Infinity use different ones.
    function hasFixedAllowance(
        address token,
        address owner,
        address permit2
    ) internal view returns (bool) {
        // Low-level staticcall rather than `try`: a token that has no code,
        // reverts, or returns short data has to degrade to "not fixed" rather
        // than bubble up and fail the whole deposit.
        (bool success, bytes memory result) = token.staticcall(
            abi.encodeCall(IERC20Minimal.allowance, (owner, permit2))
        );
        return success && result.length >= 32
            && abi.decode(result, (uint256)) == type(uint256).max;
    }
}
