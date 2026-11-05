// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";
import { SickleRegistry } from "contracts/SickleRegistry.sol";

/// @title BridgeKeeperRouter
/// @author vfat.tools
/// @notice A permissionless, stateless wrapper the bridge-intent keeper calls
/// in place of `BridgeDepositStrategy.depositFromSickleWithSignature`, so that
/// every keeper completion emits one on-chain event carrying the `intentId`
/// that joins the completion back to its origin sender event.
///
/// `BridgeDeposited` (emitted by the strategy) carries no `intentId`, and the
/// completion sets `usedIntentIds` with no event of its own, so a completion
/// cannot be joined to its origin sender event from chain data alone — the
/// link lives only in the keeper's off-chain store, which can be lost. Routing
/// completions through this contract makes the `intentId` link a first-class
/// on-chain fact, which lets the keeper ledger be reconstructed from events.
///
/// The completion itself is unchanged: the router forwards the verbatim
/// arguments to the strategy, whose EIP-712 signature check remains the sole
/// authority over whether the deposit happens. Because of that this contract
/// needs no whitelist entry of its own and grants no privileges:
///  - `depositFromSickleWithSignature` is permissionless (signature-gated), so
///    the router is just an ordinary caller of it.
///  - the Sickle ultimately touched is entered by the *strategy* — already a
///    whitelisted caller — never by this router, and is derived from `owner`
///    rather than `msg.sender`.
/// It holds no funds and has no owner, so there is nothing to secure.
///
/// EVENT INTEGRITY — `strategy` IS WHITELIST-GATED. `strategy` is a call
/// parameter, but not a blindly-trusted one: Solidity does not authenticate
/// that a `BridgeDepositStrategy(strategy)` cast points at a real strategy, so
/// without a gate anyone could pass a selector-compatible stub that returns
/// successfully without verifying a signature or touching `usedIntentIds`, and
/// make this trusted router emit a `KeeperCompletion` for a completion that
/// never happened. To prevent that the router requires
/// `registry.isWhitelistedCaller(strategy)` — the very set the protocol uses
/// to
/// decide which contracts may enter a Sickle. A stub is not in it; a real
/// current-or-retained `BridgeDepositStrategy` is. So a `KeeperCompletion` from
/// this router always corresponds to a real, signature-verified completion that
/// set `usedIntentIds`, which is what makes the reconstructed ledger
/// trustworthy.
/// `strategy` stays a parameter (not an immutable) on purpose: a
/// `BridgeDepositStrategy` redeploy retains the superseded instance in the
/// whitelist so in-flight intents still complete, and whitelists the new one
/// —
/// both pass the gate, so neither forces a redeploy of this router. `registry`,
/// by contrast, is the stable root of trust (as it is for `SickleFactory`) and
/// is fixed at construction; it must never be read from the caller-supplied
/// strategy, or a forged strategy would simply supply a forged registry.
///
/// ORIGIN IS RECONSTRUCTED, NOT ASSERTED. The event deliberately carries no
/// source-chain / sender fields. Completion is permissionless and the source
/// sender events publish the full signature, so anyone can front-run a
/// completion; any origin metadata a caller passed would therefore be
/// unauthenticated and, once the intent is consumed, unrecoverable if forged.
/// Instead a consumer recovers origin the authenticated way: index the known
/// sender set (each sender event carries the same `intentId`, on a contract
/// the consumer already trusts) and join to `KeeperCompletion` on
/// `(owner, intentId)` — the pair the strategy enforces unique via
/// `usedIntentIds`. That join resolves to exactly the one real sender event
/// that signed the intent regardless of who submitted the completion, so a
/// front-run cannot forge or hide the true origin — it can only race to be
/// the
/// address that pays gas. The event carries only what is cryptographically
/// bound to the intent (`intentId`) plus destination facts (`strategy`,
/// `token`, `amount`).
contract BridgeKeeperRouter {
    /// @notice The SickleRegistry whose caller whitelist authenticates
    /// `strategy`. Fixed at construction — the router's root of trust.
    SickleRegistry public immutable registry;

    /// @notice Thrown when `strategy` is not a whitelisted Sickle caller, i.e.
    /// not a real current-or-retained `BridgeDepositStrategy`.
    error StrategyNotWhitelisted(address strategy);

    /// @notice Emitted once per routed completion. `(owner, intentId)` joins
    /// this destination-side completion to the origin sender event of the same
    /// id; `strategy` records which (possibly superseded) deposit strategy
    /// completed it.
    /// @param intentId The bridge intent's id, shared with its sender event.
    /// @param owner The Sickle owner the intent was signed for.
    /// @param strategy The `BridgeDepositStrategy` that completed the intent.
    /// @param token The delivered token consumed by the completion.
    /// @param amount The amount the intent authorised.
    event KeeperCompletion(
        bytes32 indexed intentId,
        address indexed owner,
        address strategy,
        address token,
        uint256 amount
    );

    /// @param registry_ The SickleRegistry whose caller whitelist gates
    /// `strategy`. Must be the trusted registry for the chain; it is never
    /// re-derived from a call argument.
    constructor(
        SickleRegistry registry_
    ) {
        registry = registry_;
    }

    /// @notice Complete a delivered bridge intent through `strategy` and emit
    /// the linkage event.
    /// @dev Reverts if `strategy` is not a whitelisted caller, then reverts
    /// exactly as the strategy would — bad signature, expired deadline,
    /// amount
    /// below minimum, paused — and adds no other failure mode; no event is
    /// emitted on revert. The router keeps no state and custodies no tokens:
    /// the strategy pulls the already-delivered balance from the Sickle, not
    /// from this contract.
    function completeDeposit(
        address strategy,
        address owner,
        address token,
        uint256 amount,
        BridgeDepositStrategy.DepositParams calldata params,
        bytes32 intentId,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (!registry.isWhitelistedCaller(strategy)) {
            revert StrategyNotWhitelisted(strategy);
        }
        BridgeDepositStrategy(strategy)
            .depositFromSickleWithSignature(
                owner, token, amount, params, intentId, deadline, signature
            );
        emit KeeperCompletion(intentId, owner, strategy, token, amount);
    }
}
