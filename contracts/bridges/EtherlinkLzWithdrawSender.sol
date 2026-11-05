// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Admin } from "contracts/base/Admin.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";

/// @notice Minimal slice of the LayerZero v1 wrapped-asset bridge ABI for
/// the Etherlink-side `WrappedTokenBridge`. Mirror image of the source-side
/// `OriginalTokenBridge` API; the destination contract signature differs
/// because the reverse direction includes a `remoteChainId` (LZ v1 Eth chain
/// id 101) and an `unwrapWeth` flag for native-ETH delivery on the source.
/// Verified 2026-05-03 against the deployed `WrappedTokenBridge` at
/// `0x1f8E735f424B7A49A885571A2fA104E8C13C26c7` on Etherlink.
interface IWrappedTokenBridge {
    struct CallParams {
        address payable refundAddress;
        address zroPaymentAddress;
    }

    function bridge(
        address localToken,
        uint16 remoteChainId,
        uint256 amount,
        address to,
        bool unwrapWeth,
        CallParams calldata callParams,
        bytes calldata adapterParams
    ) external payable;

    function withdrawalFeeBps() external view returns (uint16);

    /// @notice Local Etherlink wrapped token -> canonical source-chain token
    /// for the given LZ v1 chain id. Used to validate the
    /// `(localToken, l1Token)` pair the caller asserts at bridge time so a
    /// stale or wrong mapping cannot bridge funds against an unexecutable
    /// signed intent on the destination.
    function localToRemote(
        address localToken,
        uint16 remoteChainId
    ) external view returns (address);
}

/// @title EtherlinkLzWithdrawSender
/// @notice Etherlink-side bundler for an Etherlink -> Ethereum withdrawal
/// that terminates in `BridgeDepositStrategy.depositFromSickleWithSignature`
/// on Ethereum. Mirror image of `OpStackWithdrawSender` (which itself is
/// the symmetric counterpart of `OpStackDepositSender`); same EIP-712
/// typehash is consumed on the destination, so this contract reuses the
/// keeper-driven completion path.
///
/// @dev The LZ v1 wrapped-asset bridge does not carry an execution payload
/// to the destination unlock, identical to the OP-stack standard bridge in
/// that respect. The keeper-driven completion path is therefore mandatory:
///   1. Compute the destination Sickle address on Ethereum locally via
///      CREATE2 and target it as the `to` argument of `WrappedTokenBridge.bridge`.
///   2. Emit the EIP-712 intent payload as an event so off-chain keepers
///      know what to submit on Ethereum once the LZ message has been
///      delivered and the locked tokens have been released to the
///      predicted Sickle. The keeper relays the same
///      `(sickleOwner, params, intentId, deadline, signature)` bundle that
///      `BridgeDepositStrategy.depositFromSickleWithSignature(...)`
///      verifies.
/// One sender contract is deployed per Etherlink so the destination Sickle
/// factory / impl can be pinned. The `WrappedTokenBridge` proxy on
/// Etherlink is `0x1f8E735f424B7A49A885571A2fA104E8C13C26c7` (same address
/// as the Eth-side `OriginalTokenBridge` -- this is the canonical LZ
/// wrapped-asset-bridge convention), but the constructor keeps it
/// configurable so non-standard layouts and tests work.
///
/// @dev DEPLOYMENT PRECONDITION: the destination `SickleFactory` on
/// Ethereum MUST have `previousFactory() == address(0)`. Same rationale as
/// `OpStackWithdrawSender`: the local CREATE2 prediction here computes the
/// *new* factory's clone address, but on Ethereum
/// `BridgeDepositStrategy.depositFromSickleWithSignature(...)` calls
/// `SickleFactory.getOrDeploy(...)` which falls through to
/// `previousFactory.sickles(owner)` when a legacy Sickle exists. If the
/// user already has a Sickle on a legacy factory, the bridge target (new
/// clone) and the strategy's Sickle (legacy) would diverge and the
/// withdrawn tokens would land at an address the strategy never operates
/// on. Verified 2026-05-03 via `cast call previousFactory()` that Ethereum
/// (1) `SickleFactory` returns `address(0)`.
contract EtherlinkLzWithdrawSender is Admin {
    /// ERRORS ///

    error ZeroAddress();
    error ZeroAmount();
    error NotGuardianOrAdmin();
    error PausedError();
    /// @dev Thrown when `deadline < block.timestamp + minDeadlineBuffer`.
    /// LZ v1 message delivery typically completes in minutes once source
    /// confirmations clear, but Ethereum block confirmations + DVN signing
    /// + keeper slack mean a non-trivial buffer is still required.
    /// Accepting a deadline that cannot survive that window would burn
    /// the user's Etherlink tokens against an intent that the destination
    /// `BridgeDepositStrategy.depositFromSickleWithSignature` will refuse,
    /// stranding the funds in the L1 Sickle until manual recovery.
    error DeadlineTooSoon();
    /// @dev Thrown when the caller-asserted `l1Token` does not match the
    /// `WrappedTokenBridge.localToRemote(localToken, remoteLzChainId)`
    /// mapping. The destination signed-intent verification binds
    /// `l1Token`, so a wrong assertion here would burn the wrapped local
    /// token against an unredeemable signature on Eth.
    error TokenPairMismatch();
    /// @dev Thrown when `WrappedTokenBridge.withdrawalFeeBps() != 0`.
    /// The destination strategy verifies the signed `amount` against what
    /// arrives in the Sickle on Eth; a nonzero fee deducts from delivery
    /// and would make the gross-amount signature unredeemable, stranding
    /// the funds in the Eth Sickle. Live fee on Etherlink is currently 0
    /// but is owner-settable, so we hard-revert if it ever moves rather
    /// than racing the keeper. Bridge resumes once the fee is cleared, or
    /// a fee-aware variant is added (see SignedIntentWithdrawDesign.md).
    error WithdrawalFeeActive();
    /// @dev Thrown when `setMinDeadlineBuffer` is called with a value that
    /// is not strictly greater than the current floor. The setter is
    /// raise-only: weakening the floor is the direction that strands funds.
    error BufferNotIncreased();

    /// EVENTS ///

    /// @notice Emitted on every successful withdrawal submission. Keepers
    /// index this event on `(sourceChainId, sickleOwner, intentId)` and,
    /// once the LZ wrapped-asset-bridge unlock has fired on Ethereum and
    /// tokens are at the predicted Sickle, replay the EIP-712 intent on
    /// Ethereum.
    /// @dev `paramsBlob` is `abi.encode(BridgeDepositStrategy.DepositParams)`
    /// so keepers can `abi.decode` it without needing this contract's ABI.
    /// `sourceChainId` is Etherlink (42793); the destination is always
    /// Ethereum (1) here.
    /// @dev Both source and destination tokens are emitted because the
    /// destination signed-intent call
    /// `BridgeDepositStrategy.depositFromSickleWithSignature(sickleOwner,
    /// token, ...)` verifies the signature against the *destination*
    /// (`l1Token`) -- not the local Etherlink wrapped token. Mirrors the
    /// OP-stack pattern of including both `(l2Token, l1Token)` in
    /// `OpStackWithdrawSent`.
    event EtherlinkLzWithdrawSent(
        uint64 indexed sourceChainId,
        address indexed sickleOwner,
        bytes32 indexed intentId,
        address localToken,
        address l1Token,
        uint256 amount,
        uint256 deadline,
        address predictedL1Sickle,
        bytes paramsBlob,
        bytes signature
    );

    event GuardianSet(address oldGuardian, address newGuardian);
    /// @notice Emitted when the deadline floor is raised. Keepers index this
    /// so they can widen the deadline they sign before the new floor bites.
    event MinDeadlineBufferRaised(uint256 previousBuffer, uint256 newBuffer);
    event PausedSet(bool paused);

    /// IMMUTABLES ///

    /// @notice Source chain ID (this contract's chain, 42793 for Etherlink).
    /// Included in the emitted event so a single keeper indexer can
    /// multiplex across senders without needing per-sender configuration.
    uint64 public immutable sourceChainId;
    /// @notice LZ v1 chain id of the destination (101 for Ethereum). The
    /// `WrappedTokenBridge` requires this argument on every `bridge` call;
    /// pinning it at construction keeps the sender single-purpose
    /// (Etherlink -> Ethereum), matching the OP-stack pattern of one
    /// sender per (source, destination) pair.
    uint16 public immutable remoteLzChainId;
    /// @notice LZ v1 wrapped-asset bridge proxy on Etherlink. Stored as
    /// `IWrappedTokenBridge` for typing; configurable so non-standard
    /// layouts and tests work.
    IWrappedTokenBridge public immutable lzBridge;
    /// @notice Address of the `SickleFactory` on Ethereum. Stored as a raw
    /// `address`: we never call into it from Etherlink. Used as the
    /// deployer argument when computing the destination Sickle's CREATE2
    /// address.
    address public immutable destinationSickleFactory;
    /// @notice Address of the `Sickle` implementation on Ethereum. The
    /// proxy bytecode hash for `Clones.predictDeterministicAddress` is
    /// derived from this implementation.
    address public immutable destinationSickleImplementation;
    /// @notice Minimum buffer (in seconds) that the signed deadline must
    /// leave before expiry, measured from the Etherlink burn block
    /// timestamp. Set to cover LZ v1 message-delivery latency (Ethereum
    /// confirmations + DVN sigs) plus keeper slack -- a value of ~30
    /// minutes is the recommended default. Setting it too low strands
    /// user tokens in the Eth Sickle if `depositFromSickleWithSignature`
    /// is called after the signed deadline; setting it too high
    /// inconveniences users that want short-deadline reverts.
    ///
    /// @dev Mutable, but RAISE-ONLY (`setMinDeadlineBuffer`). It encodes a
    /// value LayerZero owns and can change: DVN set, confirmation counts
    /// and relayer latency are all remote configuration. An immutable would
    /// have to be fixed by redeploying the sender -- new address, plan
    /// entry, allowlist row, configure run -- to change one integer, and
    /// until that happened every withdrawal through it would accept
    /// deadlines that cannot survive delivery.
    ///
    /// Raise-only keeps the safety property immutability was buying: the
    /// floor can never be weakened, so no admin key or fat finger can
    /// shorten it beneath real delivery latency. The dangerous direction
    /// (latency grows) becomes one admin transaction; the harmless
    /// direction needs no action.

    /// STORAGE ///

    uint256 public minDeadlineBuffer;

    address public guardian;
    bool public paused;

    /// CONSTRUCTOR ///

    constructor(
        uint64 sourceChainId_,
        uint16 remoteLzChainId_,
        address lzBridge_,
        address destinationSickleFactory_,
        address destinationSickleImplementation_,
        uint256 minDeadlineBuffer_,
        address admin_,
        address guardian_
    ) Admin(admin_) {
        if (
            lzBridge_ == address(0) || destinationSickleFactory_ == address(0)
                || destinationSickleImplementation_ == address(0)
        ) {
            revert ZeroAddress();
        }
        sourceChainId = sourceChainId_;
        remoteLzChainId = remoteLzChainId_;
        lzBridge = IWrappedTokenBridge(lzBridge_);
        destinationSickleFactory = destinationSickleFactory_;
        destinationSickleImplementation = destinationSickleImplementation_;
        minDeadlineBuffer = minDeadlineBuffer_;
        guardian = guardian_;
        emit GuardianSet(address(0), guardian_);
    }

    /// ADMIN ///

    function setGuardian(
        address newGuardian
    ) external onlyAdmin {
        emit GuardianSet(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Raise the minimum deadline buffer. Admin only, and strictly
    /// increasing -- see the `minDeadlineBuffer` docs for why it cannot be
    /// lowered. Use this when LayerZero delivery latency lengthens rather
    /// than redeploying the sender.
    function setMinDeadlineBuffer(
        uint256 newBuffer
    ) external onlyAdmin {
        if (newBuffer <= minDeadlineBuffer) revert BufferNotIncreased();
        emit MinDeadlineBufferRaised(minDeadlineBuffer, newBuffer);
        minDeadlineBuffer = newBuffer;
    }

    /// @notice Emergency pause; either guardian or admin may flip it on.
    function pause() external {
        if (msg.sender != guardian && msg.sender != admin) {
            revert NotGuardianOrAdmin();
        }
        if (paused) return;
        paused = true;
        emit PausedSet(true);
    }

    function unpause() external onlyAdmin {
        if (!paused) return;
        paused = false;
        emit PausedSet(false);
    }

    /// VIEW ///

    /// @notice CREATE2 prediction for `sickleOwner`'s Sickle on Ethereum.
    /// Mirrors `SickleFactory.predict` (salt = `keccak256(abi.encode(owner))`,
    /// deployer = destination factory, implementation = destination
    /// Sickle impl).
    function predictDestinationSickle(
        address sickleOwner
    ) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(sickleOwner));
        return Clones.predictDeterministicAddress(
            destinationSickleImplementation, salt, destinationSickleFactory
        );
    }

    /// EXTERNAL ///

    /// @notice Pull `amount` of `localToken` from the caller, send through
    /// the Etherlink-side `WrappedTokenBridge` to the predicted Ethereum
    /// Sickle, and emit the keeper payload.
    /// @dev The caller is the user's Sickle on Etherlink (typically via
    /// `BridgeLib.bridge`, which approves this contract before invoking).
    /// The signed intent does NOT have to be produced by `msg.sender`;
    /// the destination strategy verifies the signature against
    /// `sickleOwner`, so this contract only needs to forward the bytes
    /// accurately.
    /// @dev `msg.value` MUST cover the LZ native fee. Any unspent fee is
    /// refunded by the bridge to `callParams.refundAddress` (set to
    /// `msg.sender` here).
    /// @param adapterParams LZ v1 adapter params. Type 1 packed as
    /// `abi.encodePacked(uint16(1), uint256(gasLimit))` is the standard
    /// form; the destination LZ relayer needs roughly 200k gas to execute
    /// the wrapped-token unlock on Ethereum.
    function bridgeWithdraw(
        address localToken,
        address l1Token,
        address sickleOwner,
        uint256 amount,
        BridgeDepositStrategy.DepositParams calldata params,
        bytes32 intentId,
        uint256 deadline,
        bytes calldata signature,
        bytes calldata adapterParams
    ) external payable {
        if (paused) revert PausedError();
        if (
            localToken == address(0) || l1Token == address(0)
                || sickleOwner == address(0)
        ) {
            revert ZeroAddress();
        }
        if (amount == 0) revert ZeroAmount();
        if (deadline < block.timestamp + minDeadlineBuffer) {
            revert DeadlineTooSoon();
        }
        // F1: validate the (localToken, l1Token) pair against the bridge's
        // own mapping so a stale or wrong assertion cannot bridge funds
        // against an unredeemable signed intent on Eth.
        if (lzBridge.localToRemote(localToken, remoteLzChainId) != l1Token) {
            revert TokenPairMismatch();
        }
        // F2: the WrappedTokenBridge deducts `withdrawalFeeBps` (owner-
        // settable, currently 0 on mainnet) from the unlock amount before
        // delivery on Eth. The signed-intent destination call binds the
        // pre-fee amount, so any nonzero fee makes the signature
        // unredeemable. Refuse rather than race the keeper.
        if (lzBridge.withdrawalFeeBps() != 0) revert WithdrawalFeeActive();

        SafeTransferLib.safeTransferFrom(
            localToken, msg.sender, address(this), amount
        );
        // approve(0) -> approve(amount) for USDT-style ERC20s that revert
        // on a non-zero -> non-zero approval.
        SafeTransferLib.safeApprove(localToken, address(lzBridge), 0);
        SafeTransferLib.safeApprove(localToken, address(lzBridge), amount);

        address sickle = _bridgeAndComputeSickle(localToken, amount, sickleOwner, adapterParams);

        // The wrapped-asset bridge burns from `msg.sender` (this contract)
        // via the wrapped token's `burn` -- it does not call `transferFrom`
        // a second time, so the allowance set above survives the call.
        // Clear it for the same reasons OpStackWithdrawSender does.
        SafeTransferLib.safeApprove(localToken, address(lzBridge), 0);

        _emitWithdrawSent(
            localToken,
            l1Token,
            sickleOwner,
            intentId,
            amount,
            deadline,
            sickle,
            abi.encode(params),
            signature
        );
    }

    /// @dev Split out from `bridgeWithdraw` to keep the outer function
    /// under the EVM stack limit. The `paramsBlob` is pre-encoded by the
    /// caller so this helper takes plain `bytes memory` rather than the
    /// calldata struct, freeing a stack slot.
    function _emitWithdrawSent(
        address localToken,
        address l1Token,
        address sickleOwner,
        bytes32 intentId,
        uint256 amount,
        uint256 deadline,
        address sickle,
        bytes memory paramsBlob,
        bytes calldata signature
    ) private {
        emit EtherlinkLzWithdrawSent(
            sourceChainId,
            sickleOwner,
            intentId,
            localToken,
            l1Token,
            amount,
            deadline,
            sickle,
            paramsBlob,
            signature
        );
    }

    /// @dev Split out from `bridgeWithdraw` to keep the outer function
    /// under the EVM stack limit. Predicts the destination Sickle, posts
    /// the LZ unlock message, and returns the Sickle address for the
    /// emitted event.
    function _bridgeAndComputeSickle(
        address localToken,
        uint256 amount,
        address sickleOwner,
        bytes calldata adapterParams
    ) private returns (address sickle) {
        sickle = predictDestinationSickle(sickleOwner);
        lzBridge.bridge{ value: msg.value }(
            localToken,
            remoteLzChainId,
            amount,
            sickle,
            // unwrapWeth = false: keep WETH as wrapped on Eth so the
            // destination strategy's deposit params can pull it as a
            // standard ERC20 the same way Sickle handles WETH today.
            // Setting this true would deliver native ETH to the Sickle,
            // which the deposit path is not built to receive.
            false,
            IWrappedTokenBridge.CallParams({
                refundAddress: payable(msg.sender),
                zroPaymentAddress: address(0)
            }),
            adapterParams
        );
    }
}
