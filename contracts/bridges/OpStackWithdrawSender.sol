// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Admin } from "contracts/base/Admin.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";

/// @notice Minimal slice of the OP-Stack `L2StandardBridge` ABI we call.
/// The L2StandardBridge predeploy at `0x4200...0010` inherits the same
/// `bridgeERC20To` selector as the L1 side; signatures are identical, only
/// the direction of the underlying message differs.
interface IL2StandardBridge {
    function bridgeERC20To(
        address localToken,
        address remoteToken,
        address to,
        uint256 amount,
        uint32 minGasLimit,
        bytes calldata extraData
    ) external;
}

/// @title OpStackWithdrawSender
/// @notice L2-side bundler for an OP-Stack L2 -> Ethereum withdrawal that
/// terminates in `BridgeDepositStrategy.depositFromSickleWithSignature` on
/// Ethereum. Mirror image of `OpStackDepositSender`; same EIP-712 typehash
/// (`SICKLE_DEPOSIT_TYPEHASH`) is consumed on the destination, so this
/// contract reuses the keeper-driven completion path.
///
/// @dev OP-Stack `L2StandardBridge` does not carry an execution payload to
/// the L1 finalization, and the protocol-level finalization itself is
/// gated by a multi-day challenge window (currently ~7 days on mainnet).
/// The keeper-driven completion path is therefore mandatory:
///   1. Compute the destination Sickle address on Ethereum locally via
///      CREATE2 and target it as the `to` argument of `bridgeERC20To`.
///      Mirrors `OpStackDepositSender.predictDestinationSickle`.
///   2. Emit the EIP-712 intent payload as an event so off-chain keepers
///      know what to submit on Ethereum once the OP-stack finalization
///      window has elapsed AND `OptimismPortal.finalizeWithdrawalTransaction`
///      has been called for this withdrawal. The keeper relays the same
///      `(sickleOwner, params, intentId, deadline, signature)` bundle that
///      `BridgeDepositStrategy.depositFromSickleWithSignature(...)`
///      verifies.
/// One sender contract is deployed per L2 chain so the destination Sickle
/// factory / impl can be pinned per source chain. The L2StandardBridge
/// proxy is the canonical OP-stack predeploy on every L2 in the Superchain
/// (`0x4200000000000000000000000000000000000010`), but the constructor
/// keeps it configurable so the contract works on non-standard layouts and
/// in tests.
///
/// @dev DEPLOYMENT PRECONDITION: the destination `SickleFactory` on
/// Ethereum MUST have `previousFactory() == address(0)`. Same rationale as
/// `OpStackDepositSender`: the local CREATE2 prediction here computes the
/// *new* factory's clone address, but on Ethereum
/// `BridgeDepositStrategy.depositFromSickleWithSignature(...)` calls
/// `SickleFactory.getOrDeploy(...)` which falls through to
/// `previousFactory.sickles(owner)` when a legacy Sickle exists. If the
/// user already has a Sickle on the legacy factory, the bridge target
/// (new clone) and the strategy's Sickle (legacy) would diverge and the
/// withdrawn tokens would land at an address the strategy never operates
/// on. Verified 2026-05-02 via `cast call previousFactory()` that
/// Ethereum (1) returns `address(0)`.
contract OpStackWithdrawSender is Admin {
    /// ERRORS ///

    error ZeroAddress();
    error ZeroAmount();
    error NotGuardianOrAdmin();
    error PausedError();
    /// @dev Thrown when `deadline < block.timestamp + minDeadlineBuffer`.
    /// The reverse path's L1 zap-on-arrival cannot fire until the OP-stack
    /// withdrawal has been proven and finalized through the OptimismPortal,
    /// which on mainnet is gated by a multi-day challenge window. Accepting
    /// a deadline that cannot survive that window would burn the user's L2
    /// tokens against an intent that the destination
    /// `BridgeDepositStrategy.depositFromSickleWithSignature` will refuse,
    /// stranding the funds in the L1 Sickle until manual recovery.
    error DeadlineTooSoon();
    /// @dev Thrown when `setMinDeadlineBuffer` is called with a value that
    /// is not strictly greater than the current floor. The setter is
    /// raise-only: weakening the floor is the direction that strands funds.
    error BufferNotIncreased();

    /// EVENTS ///

    /// @notice Emitted on every successful withdrawal submission. Keepers
    /// index this event on `(sourceChainId, sickleOwner, intentId)` and,
    /// once the OP-stack withdrawal has been proven and finalized through
    /// the OptimismPortal on Ethereum, replay the EIP-712 intent on the
    /// destination chain.
    /// @dev `paramsBlob` is `abi.encode(BridgeDepositStrategy.DepositParams)`
    /// so keepers can `abi.decode` it without needing this contract's ABI.
    /// `sourceChainId` is the chain emitting the event (the L2); the
    /// destination is always Ethereum here.
    event OpStackWithdrawSent(
        uint64 indexed sourceChainId,
        address indexed sickleOwner,
        bytes32 indexed intentId,
        address l2Token,
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

    /// @notice Source chain ID (this contract's chain). Included in the
    /// emitted event so a single keeper indexer can multiplex across
    /// senders without needing per-sender configuration.
    uint64 public immutable sourceChainId;
    /// @notice OP-Stack `L2StandardBridge` predeploy on this L2. Stored as
    /// `IL2StandardBridge` for typing; the address is configurable so
    /// non-standard layouts and tests work.
    IL2StandardBridge public immutable l2Bridge;
    /// @notice Address of the `SickleFactory` on Ethereum. Stored as a
    /// raw `address`: we never call into it from this L2. Used as the
    /// deployer argument when computing the destination Sickle's CREATE2
    /// address.
    address public immutable destinationSickleFactory;
    /// @notice Address of the `Sickle` implementation on Ethereum. The
    /// proxy bytecode hash for `Clones.predictDeterministicAddress` is
    /// derived from this implementation.
    address public immutable destinationSickleImplementation;

    /// STORAGE ///

    /// @notice Minimum buffer (in seconds) that the signed deadline must
    /// leave before expiry, measured from the L2 burn block timestamp.
    /// Sized per chain to cover the OP-stack `OptimismPortal`
    /// challenge-window finalization plus keeper slack. Setting it too low
    /// strands user tokens in the L1 Sickle if
    /// `depositFromSickleWithSignature` is called after the signed
    /// deadline; setting it too high inconveniences users that want
    /// short-deadline reverts.
    ///
    /// @dev Mutable, but RAISE-ONLY (`setMinDeadlineBuffer`). It encodes a
    /// value the chain owns and can change: the portal enforces
    /// `proofMaturityDelaySeconds` plus `disputeGameFinalityDelaySeconds`,
    /// and a chain migrating from the legacy `L2OutputOracle` to fault
    /// proofs lengthens its effective window. An immutable would have to be
    /// fixed by redeploying the sender -- new address, plan entry, allowlist
    /// row, configure run -- to change one integer, and until that happened
    /// every withdrawal through it would accept deadlines that cannot
    /// survive finalization.
    ///
    /// Raise-only keeps the safety property immutability was buying: the
    /// floor can never be weakened, so no admin key or fat finger can
    /// shorten it beneath a live window. The dangerous direction (chain
    /// lengthens its window) becomes one admin transaction; the harmless
    /// direction (chain shortens it) needs no action, the buffer is just
    /// conservative.
    uint256 public minDeadlineBuffer;

    address public guardian;
    bool public paused;

    /// CONSTRUCTOR ///

    constructor(
        uint64 sourceChainId_,
        address l2Bridge_,
        address destinationSickleFactory_,
        address destinationSickleImplementation_,
        uint256 minDeadlineBuffer_,
        address admin_,
        address guardian_
    ) Admin(admin_) {
        if (
            l2Bridge_ == address(0) || destinationSickleFactory_ == address(0)
                || destinationSickleImplementation_ == address(0)
        ) {
            revert ZeroAddress();
        }
        sourceChainId = sourceChainId_;
        l2Bridge = IL2StandardBridge(l2Bridge_);
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
    /// lowered. Use this when the destination chain lengthens its
    /// finalization window (for example on a fault-proof migration) rather
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

    /// @notice Pull `amount` of `l2Token` from the caller, send through
    /// the OP-Stack `L2StandardBridge` to the predicted Ethereum Sickle,
    /// and emit the keeper payload.
    /// @dev The caller is the user's Sickle on this L2 (typically via
    /// `BridgeLib.bridge`, which approves this contract before invoking).
    /// The signed intent does NOT have to be produced by `msg.sender`;
    /// the destination strategy verifies the signature against
    /// `sickleOwner`, so this contract only needs to forward the bytes
    /// accurately.
    function bridgeWithdraw(
        address l2Token,
        address l1Token,
        uint32 minGasLimit,
        address sickleOwner,
        uint256 amount,
        BridgeDepositStrategy.DepositParams calldata params,
        bytes32 intentId,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (paused) revert PausedError();
        if (
            l2Token == address(0) || l1Token == address(0)
                || sickleOwner == address(0)
        ) {
            revert ZeroAddress();
        }
        if (amount == 0) revert ZeroAmount();
        // The L2 burn happens immediately, but the L1 zap can only fire
        // after the OptimismPortal finalization window. Reject any
        // deadline that the L1 keeper cannot possibly satisfy.
        if (deadline < block.timestamp + minDeadlineBuffer) {
            revert DeadlineTooSoon();
        }

        SafeTransferLib.safeTransferFrom(
            l2Token, msg.sender, address(this), amount
        );
        // approve(0) -> approve(amount) to be safe for ERC20s that revert
        // on a non-zero -> non-zero approval (USDT-style). The post-call
        // clear below means we always start from zero, but keep the pair
        // for defensive symmetry with `BridgeLib.bridge`.
        SafeTransferLib.safeApprove(l2Token, address(l2Bridge), 0);
        SafeTransferLib.safeApprove(l2Token, address(l2Bridge), amount);

        address sickle = predictDestinationSickle(sickleOwner);

        l2Bridge.bridgeERC20To(
            l2Token, l1Token, sickle, amount, minGasLimit, ""
        );

        // OP-Stack `OptimismMintableERC20` tokens are burned from
        // `msg.sender` directly on the L2 standard-bridge path -- the
        // bridge does not call `transferFrom`, so the allowance set
        // above survives the call. Clear it explicitly so a second
        // `bridgeWithdraw` for the same token works on USDT-style
        // ERC20s, and so that the sender never carries lingering
        // approvals to the predeploy.
        SafeTransferLib.safeApprove(l2Token, address(l2Bridge), 0);

        emit OpStackWithdrawSent(
            sourceChainId,
            sickleOwner,
            intentId,
            l2Token,
            l1Token,
            amount,
            deadline,
            sickle,
            abi.encode(params),
            signature
        );
    }
}
