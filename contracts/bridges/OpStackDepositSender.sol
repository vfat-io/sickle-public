// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Admin } from "contracts/base/Admin.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";

/// @notice Minimal slice of the OP-Stack `L1StandardBridge` ABI we call.
interface IL1StandardBridge {
    function bridgeERC20To(
        address localToken,
        address remoteToken,
        address to,
        uint256 amount,
        uint32 minGasLimit,
        bytes calldata extraData
    ) external;
}

/// @title OpStackDepositSender
/// @notice Source-side bundler for an Ethereum -> OP-Stack L2 bridge that
/// terminates in `BridgeDepositStrategy.depositFromSickleWithSignature` on
/// the destination chain.
/// @dev OP-Stack `L1StandardBridge` does not carry an execution payload to
/// the L2 token mint, so the keeper-driven completion path is the only
/// option. This sender handles two responsibilities:
///   1. Compute the destination Sickle address locally via CREATE2 and
///      target it as the `to` argument of `bridgeERC20To`. There is no
///      external call to the destination factory
///      (which has no code on Eth); the prediction is locally computed
///      from the destination factory + Sickle implementation addresses
///      provided at construction.
///   2. Emit the EIP-712 intent payload as an event so off-chain keepers
///      know what to submit on the destination chain. The keeper relays
///      the same `(sickleOwner, params, intentId, deadline, signature)`
///      bundle that the destination strategy verifies.
/// One sender contract is deployed per (Ethereum, destination L2) pair so
/// the L1 bridge proxy address and destination Sickle factory / impl can be
/// pinned per chain. Same shape as `CcipDepositSenderToBase`.
///
/// @dev DEPLOYMENT PRECONDITION: the destination `SickleFactory` MUST have
/// `previousFactory() == address(0)`. The local CREATE2 prediction here
/// computes the *new* factory's clone address, but on the destination
/// `BridgeDepositStrategy.depositFromSickleWithSignature(...)` calls
/// `SickleFactory.getOrDeploy(...)` which falls through to
/// `previousFactory.sickles(owner)` when a legacy Sickle exists. If the
/// user already has a Sickle on the legacy factory, the bridge target
/// (new clone) and the strategy's Sickle (legacy) would diverge and the
/// bridged tokens would land at an address the strategy never operates
/// on. Verified 2026-05-01 via `cast call previousFactory()` that Swell
/// (1923), Fraxtal (252), Metal L2 (1750), and Ethereum (1) all return
/// `address(0)`. If a future destination has a non-zero
/// `previousFactory`, either migrate the legacy Sickles to the new
/// factory upstream of using this sender, or refactor it to take the L2
/// recipient as a caller-supplied argument.
contract OpStackDepositSender is Admin {
    /// ERRORS ///

    error ZeroAddress();
    error ZeroAmount();
    error NotGuardianOrAdmin();
    error PausedError();

    /// EVENTS ///

    /// @notice Emitted on every successful bridge submission. Keepers index
    /// this event on `(destChainId, sickleOwner, intentId)` and replay the
    /// EIP-712 intent on the destination chain once the L2 token mint
    /// finalizes at `predictedSickle`.
    /// @dev `paramsBlob` is `abi.encode(BridgeDepositStrategy.DepositParams)`
    /// so keepers can `abi.decode` it without needing this contract's ABI.
    event OpStackDepositSent(
        uint64 indexed destChainId,
        address indexed sickleOwner,
        bytes32 indexed intentId,
        address l1Token,
        address l2Token,
        uint256 amount,
        uint256 deadline,
        address predictedSickle,
        bytes paramsBlob,
        bytes signature
    );

    event GuardianSet(address oldGuardian, address newGuardian);
    event PausedSet(bool paused);

    /// IMMUTABLES ///

    /// @notice Destination chain ID, included in the emitted event so a
    /// single keeper indexer can multiplex across senders without needing
    /// per-sender configuration.
    uint64 public immutable destChainId;
    /// @notice OP-Stack L1StandardBridge proxy on Ethereum for this
    /// destination. Each L2 has its own L1 proxy.
    IL1StandardBridge public immutable l1Bridge;
    /// @notice Address of the `SickleFactory` on the destination chain.
    /// Stored as a raw `address`: we never call into it from Ethereum.
    /// Used as the deployer argument when computing the destination
    /// Sickle's CREATE2 address.
    address public immutable destinationSickleFactory;
    /// @notice Address of the `Sickle` implementation on the destination
    /// chain. The proxy bytecode hash for `Clones.predictDeterministicAddress`
    /// is derived from this implementation.
    address public immutable destinationSickleImplementation;

    /// STORAGE ///

    address public guardian;
    bool public paused;

    /// CONSTRUCTOR ///

    constructor(
        uint64 destChainId_,
        address l1Bridge_,
        address destinationSickleFactory_,
        address destinationSickleImplementation_,
        address admin_,
        address guardian_
    ) Admin(admin_) {
        if (
            l1Bridge_ == address(0) || destinationSickleFactory_ == address(0)
                || destinationSickleImplementation_ == address(0)
        ) {
            revert ZeroAddress();
        }
        destChainId = destChainId_;
        l1Bridge = IL1StandardBridge(l1Bridge_);
        destinationSickleFactory = destinationSickleFactory_;
        destinationSickleImplementation = destinationSickleImplementation_;
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

    /// @notice CREATE2 prediction for `sickleOwner`'s Sickle on the
    /// destination chain. Mirrors `SickleFactory.predict` (salt =
    /// `keccak256(abi.encode(owner))`, deployer = destination factory,
    /// implementation = destination Sickle impl).
    function predictDestinationSickle(
        address sickleOwner
    ) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(sickleOwner));
        return Clones.predictDeterministicAddress(
            destinationSickleImplementation, salt, destinationSickleFactory
        );
    }

    /// EXTERNAL ///

    /// @notice Pull `amount` of `l1Token` from the caller, deposit through
    /// the OP-Stack `L1StandardBridge` to the predicted destination Sickle,
    /// and emit the keeper payload.
    /// @dev The caller is the user (or their Sickle multicall on Eth). The
    /// signed intent does NOT have to be produced by `msg.sender`; the
    /// destination strategy verifies the signature against `sickleOwner`,
    /// so this contract only needs to forward the bytes accurately.
    function bridgeDeposit(
        address l1Token,
        address l2Token,
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
            l1Token == address(0) || l2Token == address(0)
                || sickleOwner == address(0)
        ) {
            revert ZeroAddress();
        }
        if (amount == 0) revert ZeroAmount();

        SafeTransferLib.safeTransferFrom(
            l1Token, msg.sender, address(this), amount
        );
        SafeTransferLib.safeApprove(l1Token, address(l1Bridge), amount);

        address sickle = predictDestinationSickle(sickleOwner);

        l1Bridge.bridgeERC20To(
            l1Token, l2Token, sickle, amount, minGasLimit, ""
        );

        emit OpStackDepositSent(
            destChainId,
            sickleOwner,
            intentId,
            l1Token,
            l2Token,
            amount,
            deadline,
            sickle,
            abi.encode(params),
            signature
        );
    }
}
