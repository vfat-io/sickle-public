// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "lib/solmate/src/utils/SafeTransferLib.sol";
import { IWETH9 as IWETH } from "contracts/interfaces/external/IWETH.sol";

/// @title WethUnwrapper
/// @notice Stateless, ownerless, fee-free helper that unwraps WETH to native
/// ETH and forwards it to the caller with a full-gas `.call`.
/// @dev Motivation: the canonical WETH9 `withdraw` returns ETH to `msg.sender`
/// via a 2300-gas `.transfer` stipend. EIP-7702-delegated EOAs and
/// smart-contract accounts whose `receive()` / `fallback()` costs more than
/// 2300 gas cannot receive that transfer, so calling `WETH9.withdraw()`
/// directly reverts for them. This contract pulls the caller's WETH, withdraws
/// it here (this contract's `receive()` is trivially cheap and comfortably
/// under the stipend), then forwards the ETH to the caller with
/// `.call{ value: ... }`, which forwards all remaining gas.
///
/// Security model:
/// - No owner, no admin, no fee, no storage: nothing to configure, upgrade,
///   pause, or drain. Callers keep 100% of their ETH.
/// - `weth` is a per-call argument (not a constructor arg / immutable), so the
///   creation code, and thus the CREATE2 address, is identical on every chain.
///   One deterministic salt yields ONE address everywhere.
/// - Reentrancy: the contract holds no state and forwards exactly `amount` in a
///   single trailing call to `msg.sender`. A reentrant call merely repeats the
///   pull / withdraw / forward against whatever the reentering caller has
///   itself approved; there is no accounting for it to corrupt, and it can
///   never move another account's WETH or ETH.
/// - Balance guard: `unwrap` requires this contract's ETH balance to rise by at
///   least `amount` across the `withdraw` before forwarding, so a call can only
///   ever pay out ETH that arrived during that same call. This is what makes
///   the "nothing to drain" claim true even though `receive()` accepts ETH and
///   the deterministic address is publicly known: stray ETH mistakenly or
///   force-sent to the address cannot be siphoned out by a no-op `weth` whose
///   `transferFrom` / `withdraw` succeed without moving value.
/// - A caller that passes a malicious `weth` can only harm itself: every token
///   movement is scoped to `msg.sender`'s own balance and approval, and the ETH
///   is returned to `msg.sender`.
contract WethUnwrapper {
    /// @notice The forwarding `.call` to `msg.sender` returned false (the
    /// recipient reverted or otherwise rejected the ETH).
    error EthTransferFailed();

    /// @notice `weth.withdraw` did not deliver `amount` native ETH to this
    /// contract during the call (e.g. a caller-supplied token that moved no
    /// value). Blocks a no-op token from forwarding ETH this call did not
    /// itself produce, so pre-existing / stray ETH can never be drained.
    error InsufficientEthReceived();

    /// @notice Unwrap `amount` of `weth` held by the caller into native ETH and
    /// forward it to the caller with full gas.
    /// @dev The caller MUST have approved this contract for at least `amount`
    /// of `weth` beforehand. `weth` must be a WETH9-compatible token whose
    /// `withdraw` returns `amount` native ETH to this contract.
    /// @param weth Address of the WETH9-compatible token to unwrap.
    /// @param amount Amount of WETH to unwrap and return as native ETH.
    function unwrap(
        address weth,
        uint256 amount
    ) external {
        // Snapshot ETH before the pull / withdraw so we can prove that THIS
        // call's `withdraw` actually delivered `amount` native ETH, rather than
        // paying out of any balance that was already sitting here (stray ETH
        // mistakenly or force-sent to the publicly known deterministic
        // address). Without this, a caller-supplied no-op `weth` whose
        // `transferFrom` / `withdraw` succeed without moving value could drain
        // that stray ETH.
        uint256 balanceBefore = address(this).balance;
        SafeTransferLib.safeTransferFrom(
            weth, msg.sender, address(this), amount
        );
        IWETH(weth).withdraw(amount);
        if (address(this).balance < balanceBefore + amount) {
            revert InsufficientEthReceived();
        }
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert EthTransferFailed();
    }

    /// @notice Accept the native ETH sent by `WETH9.withdraw`.
    receive() external payable { }
}
