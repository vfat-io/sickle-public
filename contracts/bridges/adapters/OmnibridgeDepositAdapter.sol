// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";
import {
    IOmnibridgeAmb,
    IOmnibridgeMediator,
    IOmnibridgeReceiver
} from "contracts/bridges/interfaces/IOmnibridge.sol";

/// @title OmnibridgeDepositAdapter
/// @notice Destination adapter for the xDai-fork Omnibridge that connects
/// Ethereum (`ForeignOmnibridge`) and PulseChain (`HomeOmnibridge`). Turns an
/// arrival into a farm entry: the sender calls
/// `relayTokensAndCall(token, thisAdapter, value, payload)` on the origin
/// mediator, the destination mediator delivers the local ERC20 here and then
/// calls `onTokenBridged`, and this contract hands the tokens to
/// `BridgeDepositStrategy`.
///
/// One implementation serves both sides; the direction is fixed by the
/// constructor. On PulseChain it receives the Omnibridge-minted canonical
/// assets (`DAI from Ethereum`, `USD Coin from Ethereum`); on Ethereum it
/// receives the unlocked mainnet original.
///
/// @dev **A failed delivery is recorded, not reverted.**
/// `BasicOmnibridge._receiverCallback` is a bare `.call` with the result
/// discarded, and it runs *after* `_handleTokens` has already minted or
/// unlocked to the recipient. Reverting here therefore does not bounce the
/// delivery the way an Across fill bounces: the AMB still marks the message
/// executed, and the tokens sit here. Worse, a reverted frame cannot record
/// anything, so those tokens would be indistinguishable from the next
/// delivery's — see the attribution note below.
///
/// So exactly one failure reverts: a caller that is not the pinned mediator,
/// which by construction delivered nothing and leaves nothing behind. Every
/// later failure — endpoint disabled, unexpected origin, undecodable
/// payload, a deposit that throws — books the delivery into
/// `strandedBalance` and returns, emitting `OmnibridgeDeliveryStranded` so
/// the loss is visible rather than silent. `rescueTokens` releases it.
///
/// For the same reason this adapter routes to `executeDeposit` and never to
/// `executeDepositStrict`: strict mode's contract is that a revert bounces
/// the fill, which holds for Across and not here. Independently, Omnibridge
/// grants destination gas from a fixed `requestGasLimit` rather than a
/// relayer's `eth_estimateGas`, so the estimator-convergence problem that
/// motivated strict mode cannot arise.
///
/// @dev **Attribution: `value` is what was announced, not what arrived.**
/// `HomeOmnibridge._handleTokens` deducts `FOREIGN_TO_HOME_FEE` and releases
/// `valueToBridge = _value - fee`, but `handleBridgedTokensAndCall` then
/// invokes the callback with the pre-fee `_value`. Fee-on-transfer tokens
/// under-deliver the same way. So the delivered amount must be measured, and
/// measuring it as `min(balance, value)` would let a short delivery top
/// itself up out of tokens an *earlier* delivery left behind — real theft
/// between users, since `relayTokensAndCall` is permissionless and anyone
/// can repeat it.
///
/// `strandedBalance[token]` is therefore subtracted first: what this message
/// delivered is `balance - strandedBalance[token]`, capped at `value`
/// because nothing above the announced amount belongs to it. The fee is zero
/// for both PulseChain stablecoins today, but the fee manager
/// (`0xBa86ca0AECA30247F9E2fd8736879997bCD01dc4`) is mutable and this
/// adapter accepts every registered token.
///
/// The ledger only tracks what arrived *through the callback*. Tokens sent
/// to this address directly are not attributed to anyone and the next
/// delivery may absorb them up to its own `value` — the same property every
/// adapter in this repo has, and not a claim any user holds.
///
/// @dev **Destination gas.** Both AMBs cap a message at `maxGasPerTx` = 2M
/// and both mediators request exactly 2M, so the callback runs with ~2M less
/// the mediator's own mint/unlock. Farm entries in this codebase have
/// measured 1.0-1.2M. `STRAND_GAS_RESERVE` is withheld from the deposit so
/// the recording arm is always affordable: without it an out-of-gas deposit
/// would revert this frame too, and the swallowed revert would leave the
/// delivery unattributed.
///
/// @dev **Authentication.** `BridgeLib` validates only the bridge contract
/// and the selector; it deliberately does not look at the recipient encoded
/// inside `bridgeCalldata`, and `relayTokensAndCall` is permissionless
/// anyway — anyone may bridge to this adapter with a payload of their
/// choosing. Three independent layers carry the weight:
///
///   1. `msg.sender` must be the pinned local mediator, and that mediator
///      must still be whitelisted — the whitelist stays as the guardian's
///      emergency kill switch over a caller that is otherwise fixed at
///      deploy time.
///   2. The pinned AMB must currently be executing a message from the pinned
///      remote mediator, on the pinned source chain. This does not restate
///      the mediator's own `onlyMediator` check: that check reads the
///      mediator's *mutable* `bridgeContract()` and
///      `mediatorContractOnOtherSide()`, whereas these are fixed here at
///      deploy time, so a re-pointed mediator fails closed instead of
///      redirecting authentication. The AMB zeroes all three context slots
///      after execution and refuses nested messages, so the check also
///      proves a message is genuinely in flight.
///   3. Authorship of the *payload* is proven by the EIP-712 signature
///      `BridgeDepositStrategy` verifies over `(owner, token, params,
///      intentId, deadline)`. Layers 1 and 2 prove the tokens came through
///      the bridge; only the signature proves who asked for the farm entry.
///
/// Pinning the origin trades availability for that guarantee: if the bridge
/// operators re-point the mediator at a new AMB, arrivals strand until this
/// adapter is redeployed. `originConfigMatchesMediator` makes that drift
/// observable before it bites.
///
/// @dev ERC20 only. `relayTokensAndCall` takes a registered ERC20; native PLS
/// and ETH reach the bridge through `WETHOmnibridgeRouter`, which exposes no
/// payload argument and so cannot produce a callback.
contract OmnibridgeDepositAdapter is BridgeAdapterBase, IOmnibridgeReceiver {
    /// @notice Why a delivery was booked to `strandedBalance` instead of
    /// being deposited.
    enum StrandReason {
        /// The guardian or admin has disabled the mediator endpoint.
        EndpointDisabled,
        /// The AMB is not relaying from the pinned remote mediator.
        UnexpectedMessageSender,
        /// The in-flight message did not originate on the pinned chain.
        UnexpectedSourceChainId,
        /// The mediator announced a value but delivered nothing new.
        NothingDelivered,
        /// The payload would not decode, or the deposit threw.
        DepositFailed
    }

    /// @notice Thrown when a caller other than the pinned mediator invokes
    /// the callback.
    error NotOmnibridgeMediator();
    /// @notice Thrown when `depositBridgedTokens` is called by anyone but
    /// this contract.
    error OnlySelf();
    /// @notice Thrown when a constructor argument that the origin proof
    /// depends on is left at its zero value.
    error InvalidOmnibridgeOrigin();

    /// @notice A delivery this adapter could not deposit. `amount` is added
    /// to `strandedBalance[token]` and is recoverable only by `rescueTokens`.
    event OmnibridgeDeliveryStranded(
        address indexed token, uint256 amount, StrandReason reason
    );

    /// @notice Emitted by `rescueTokens` so the ledger movement is auditable
    /// alongside the transfer.
    event StrandedBalanceRescued(
        address indexed token, address indexed to, uint256 amount
    );

    /// @dev Gas withheld from the deposit so the recording arm of the
    /// try/catch is always affordable. Sized well above an SSTORE plus an
    /// event, and small next to the ~1.85M the callback actually receives.
    uint256 internal constant STRAND_GAS_RESERVE = 100_000;

    BridgeDepositStrategy public immutable strategy;

    /// @notice Omnibridge mediator on this chain — the only permitted caller.
    address public immutable mediator;

    /// @notice AMB on this chain, pinned so the origin proof does not read
    /// through the mediator's mutable configuration.
    IOmnibridgeAmb public immutable amb;

    /// @notice Mediator on the origin chain that messages must come from.
    address public immutable remoteMediator;

    /// @notice Chain id that messages must originate on.
    uint256 public immutable sourceChainId;

    /// @notice Tokens held here on behalf of earlier deliveries this adapter
    /// could not deposit. No later delivery may spend them.
    mapping(address => uint256) public strandedBalance;

    constructor(
        address strategy_,
        address mediator_,
        address amb_,
        address remoteMediator_,
        uint256 sourceChainId_,
        address admin_,
        address guardian_
    ) BridgeAdapterBase(admin_, guardian_) {
        // A zero remote mediator or source chain id would make the origin
        // proof vacuous, since the AMB reads back zero when idle.
        if (
            strategy_ == address(0) || mediator_ == address(0)
                || amb_ == address(0) || remoteMediator_ == address(0)
                || sourceChainId_ == 0
        ) {
            revert InvalidOmnibridgeOrigin();
        }
        strategy = BridgeDepositStrategy(strategy_);
        mediator = mediator_;
        amb = IOmnibridgeAmb(amb_);
        remoteMediator = remoteMediator_;
        sourceChainId = sourceChainId_;
    }

    /// @notice Omnibridge destination callback. Attributes what this message
    /// actually delivered, then executes the signed farm entry.
    /// @param token Local ERC20 the mediator delivered to this adapter.
    /// @param value Amount the mediator *announced*, which is the pre-fee
    /// figure and so may exceed what arrived.
    /// @param data `abi.encode(sickleOwner, params, intentId, deadline,
    /// signature)`.
    function onTokenBridged(
        address token,
        uint256 value,
        bytes calldata data
    ) external override {
        // The only revert in this function. A caller that is not the pinned
        // mediator delivered nothing, so bouncing it strands nothing.
        if (msg.sender != mediator) revert NotOmnibridgeMediator();

        uint256 stranded = strandedBalance[token];
        uint256 balance = _tokenBalance(token);
        uint256 delivered = balance > stranded ? balance - stranded : 0;
        if (delivered > value) delivered = value;

        if (!whitelistedBridgeEndpoints[msg.sender]) {
            _strand(token, stranded, delivered, StrandReason.EndpointDisabled);
            return;
        }

        (bool originOk, StrandReason originReason) = _checkOrigin();
        if (!originOk) {
            _strand(token, stranded, delivered, originReason);
            return;
        }

        // Nothing arrived that belongs to this message. Returning without
        // touching the strategy keeps the payload's `intentId` unconsumed,
        // so the owner can still be credited by a later delivery.
        if (delivered == 0) {
            _strand(token, stranded, 0, StrandReason.NothingDelivered);
            return;
        }

        if (gasleft() < STRAND_GAS_RESERVE) {
            _strand(token, stranded, delivered, StrandReason.DepositFailed);
            return;
        }

        try this.depositBridgedTokens{ gas: gasleft() - STRAND_GAS_RESERVE }(
            token, delivered, data
        ) { }
        catch {
            _strand(token, stranded, delivered, StrandReason.DepositFailed);
        }
    }

    /// @notice Decode the payload and drive the deposit.
    /// @dev External only so `onTokenBridged` can `try`/`catch` it: an
    /// undecodable payload or a throwing deposit must roll the token
    /// transfer back and be recorded, not propagate.
    function depositBridgedTokens(
        address token,
        uint256 amount,
        bytes calldata data
    ) external {
        if (msg.sender != address(this)) revert OnlySelf();

        (
            address sickleOwner,
            BridgeDepositStrategy.DepositParams memory params,
            bytes32 intentId,
            uint256 deadline,
            bytes memory signature
        ) = abi.decode(
            data,
            (
                address,
                BridgeDepositStrategy.DepositParams,
                bytes32,
                uint256,
                bytes
            )
        );

        SafeTransferLib.safeTransfer(token, address(strategy), amount);
        strategy.executeDeposit(
            token, amount, sickleOwner, params, intentId, deadline, signature
        );
    }

    /// @notice Rescue tokens, keeping the stranded ledger in step.
    /// @dev Overrides the base so a rescue cannot leave `strandedBalance`
    /// above the tokens actually held, which would lock later deliveries out
    /// of their own funds.
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external override onlyAdmin {
        uint256 stranded = strandedBalance[token];
        if (stranded > 0) {
            strandedBalance[token] = amount >= stranded ? 0 : stranded - amount;
        }
        SafeTransferLib.safeTransfer(token, to, amount);
        emit StrandedBalanceRescued(token, to, amount);
    }

    /// @notice True while the pinned mediator still agrees with the origin
    /// this adapter was deployed against.
    /// @dev The origin is immutable by design, so drift here is a redeploy
    /// signal rather than something configuration can repair. Exposed so
    /// monitoring catches it before an arrival strands.
    function originConfigMatchesMediator() external view returns (bool) {
        return IOmnibridgeMediator(mediator).bridgeContract() == address(amb)
            && IOmnibridgeMediator(mediator).mediatorContractOnOtherSide()
                == remoteMediator;
    }

    function _strand(
        address token,
        uint256 stranded,
        uint256 delivered,
        StrandReason reason
    ) internal {
        if (delivered > 0) {
            strandedBalance[token] = stranded + delivered;
        }
        emit OmnibridgeDeliveryStranded(token, delivered, reason);
    }

    /// @dev Read through `staticcall` rather than a typed call so a
    /// misbehaving AMB cannot revert this frame; the whole point of the
    /// design is that nothing after the mediator check throws.
    function _checkOrigin()
        internal
        view
        returns (bool ok, StrandReason reason)
    {
        (bool senderRead, uint256 senderWord) =
            _ambWord(IOmnibridgeAmb.messageSender.selector);
        if (!senderRead || senderWord != uint256(uint160(remoteMediator))) {
            return (false, StrandReason.UnexpectedMessageSender);
        }
        (bool chainRead, uint256 chainWord) =
            _ambWord(IOmnibridgeAmb.messageSourceChainId.selector);
        if (!chainRead || chainWord != sourceChainId) {
            return (false, StrandReason.UnexpectedSourceChainId);
        }
        return (true, StrandReason.DepositFailed);
    }

    function _ambWord(
        bytes4 selector
    ) internal view returns (bool ok, uint256 word) {
        (bool success, bytes memory ret) =
            address(amb).staticcall(abi.encodeWithSelector(selector));
        if (!success || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
