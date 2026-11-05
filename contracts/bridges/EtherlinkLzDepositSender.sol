// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Admin } from "contracts/base/Admin.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";

/// @notice Minimal slice of the LayerZero v1 wrapped-asset bridge ABI.
/// @dev `OriginalTokenBridge` is the source-side LZ v1 contract published by
/// LayerZero Labs; canonical Eth deployment for the Etherlink lane is
/// `0x1f8E735f424B7A49A885571A2fA104E8C13C26c7` with `remoteChainId` 292.
/// The bridge locks `amountLD` of `token` and posts an LZ message to the
/// `WrappedTokenBridge` peer, which mints the bridged-asset ERC20 to `to`.
/// No execution payload is delivered to a destination contract -- this is
/// strictly a token mover, the same shape as OP-stack `L1StandardBridge`.
interface IOriginalTokenBridge {
    struct CallParams {
        address payable refundAddress;
        address zroPaymentAddress;
    }

    function bridge(
        address token,
        uint256 amountLD,
        address to,
        CallParams calldata callParams,
        bytes calldata adapterParams
    ) external payable;

    function estimateBridgeFee(
        bool useZro,
        bytes calldata adapterParams
    ) external view returns (uint256 nativeFee, uint256 zroFee);

    function supportedTokens(
        address token
    ) external view returns (bool);
}

/// @title EtherlinkLzDepositSender
/// @notice Source-side bundler for an Ethereum -> Etherlink bridge that
/// terminates in `BridgeDepositStrategy.depositFromSickleWithSignature` on
/// Etherlink.
/// @dev Mirrors `OpStackDepositSender` exactly: the underlying bridge moves
/// tokens but carries no execution payload, so destination completion is
/// keeper-driven via the same EIP-712 intent that the OP-stack senders
/// already use. The only structural difference from OP-stack is that the
/// LZ v1 wrapped-asset bridge requires a payable native fee for the LZ
/// message; this contract forwards `msg.value` and routes any unspent fee
/// back to `msg.sender` via `CallParams.refundAddress`.
///
/// Per-pair instance pattern matches `OpStackDepositSenderToSwell`: one
/// sender per (Ethereum, destination LZ chain id) pair so the bridge proxy,
/// destination Sickle factory, and destination Sickle implementation can be
/// pinned at construction.
///
/// @dev DEPLOYMENT PRECONDITION: the destination `SickleFactory` MUST have
/// `previousFactory() == address(0)`. Identical reasoning to
/// `OpStackDepositSender`: the local CREATE2 prediction targets the *new*
/// factory's clone, but on the destination
/// `BridgeDepositStrategy.depositFromSickleWithSignature(...)` calls
/// `SickleFactory.getOrDeploy(...)` which falls through to
/// `previousFactory.sickles(owner)` when a legacy Sickle exists. If the
/// user already has a Sickle on a legacy factory, the bridge target (new
/// clone) and the strategy's Sickle (legacy) would diverge and bridged
/// tokens would land at an address the strategy never operates on.
/// Verified 2026-05-02 via `cast call previousFactory()` that Etherlink
/// (42793) returns `address(0)`.
contract EtherlinkLzDepositSender is Admin {
    /// ERRORS ///

    error ZeroAddress();
    error ZeroAmount();
    error UnsupportedToken();
    error NotGuardianOrAdmin();
    error PausedError();

    /// EVENTS ///

    /// @notice Emitted on every successful bridge submission. Keepers index
    /// this event on `(destChainId, sickleOwner, intentId)` and replay the
    /// EIP-712 intent on the destination chain once the LZ message
    /// finalizes and the wrapped tokens are minted to `predictedSickle`.
    /// @dev `paramsBlob` is `abi.encode(BridgeDepositStrategy.DepositParams)`
    /// so keepers can `abi.decode` it without needing this contract's ABI.
    /// @dev Both source and destination tokens are emitted because the
    /// signed-intent destination call
    /// `BridgeDepositStrategy.depositFromSickleWithSignature(sickleOwner,
    /// token, ...)` verifies the signature against the *destination* token,
    /// not the source -- and the Eth-side `OriginalTokenBridge` exposes no
    /// `localToRemote` getter, so on-chain validation of the pair binding
    /// is not possible here. Including both addresses in the event keeps
    /// the keeper indexer self-contained (no separate L1->Etherlink
    /// mapping lookup needed). Mirrors the OP-stack pattern of including
    /// both `(l1Token, l2Token)` in `OpStackDepositSent`.
    event EtherlinkLzDepositSent(
        uint64 indexed destChainId,
        address indexed sickleOwner,
        bytes32 indexed intentId,
        address l1Token,
        address etherlinkToken,
        uint256 amount,
        uint256 deadline,
        address predictedSickle,
        bytes paramsBlob,
        bytes signature
    );

    event GuardianSet(address oldGuardian, address newGuardian);
    event PausedSet(bool paused);

    /// IMMUTABLES ///

    /// @notice Destination chain ID (e.g. 42793 for Etherlink), included in
    /// the emitted event so a single keeper indexer can multiplex across
    /// senders without per-sender configuration.
    uint64 public immutable destChainId;
    /// @notice LayerZero v1 wrapped-asset bridge proxy on Ethereum for this
    /// destination. Each LZ-bridged chain has its own L1 proxy.
    IOriginalTokenBridge public immutable lzBridge;
    /// @notice Destination Sickle factory address. Stored as a raw `address`:
    /// we never call into it from Ethereum. Used as the deployer argument
    /// when computing the destination Sickle's CREATE2 address.
    address public immutable destinationSickleFactory;
    /// @notice Destination Sickle implementation. The proxy bytecode hash
    /// for `Clones.predictDeterministicAddress` is derived from this
    /// implementation address.
    address public immutable destinationSickleImplementation;

    /// STORAGE ///

    address public guardian;
    bool public paused;

    /// CONSTRUCTOR ///

    constructor(
        uint64 destChainId_,
        address lzBridge_,
        address destinationSickleFactory_,
        address destinationSickleImplementation_,
        address admin_,
        address guardian_
    ) Admin(admin_) {
        if (
            lzBridge_ == address(0) || destinationSickleFactory_ == address(0)
                || destinationSickleImplementation_ == address(0)
        ) {
            revert ZeroAddress();
        }
        destChainId = destChainId_;
        lzBridge = IOriginalTokenBridge(lzBridge_);
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

    /// @notice Convenience pass-through to the underlying bridge's fee
    /// estimator. Callers compute `msg.value` for `bridgeDeposit` from this.
    function estimateBridgeFee(
        bytes calldata adapterParams
    ) external view returns (uint256 nativeFee) {
        (nativeFee,) = lzBridge.estimateBridgeFee(false, adapterParams);
    }

    /// EXTERNAL ///

    /// @notice Pull `amount` of `l1Token` from the caller, lock through the
    /// LZ wrapped-asset bridge to the predicted destination Sickle, and emit
    /// the keeper payload.
    /// @dev `msg.value` MUST cover the LZ native fee returned by
    /// `estimateBridgeFee`. Any unspent fee is refunded by the bridge to the
    /// `refundAddress` we pass in (`msg.sender`). The signed intent does not
    /// have to be produced by `msg.sender`; the destination strategy
    /// verifies the signature against `sickleOwner`, so this contract only
    /// needs to forward the bytes accurately.
    /// @param adapterParams LZ v1 adapter params (gas/airdrop config). Type
    /// 1 packed as `abi.encodePacked(uint16(1), uint256(gasLimit))` is the
    /// standard form; the destination LZ relayer needs roughly 200k gas to
    /// execute the wrapped-token mint.
    function bridgeDeposit(
        address l1Token,
        address etherlinkToken,
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
            l1Token == address(0) || etherlinkToken == address(0)
                || sickleOwner == address(0)
        ) {
            revert ZeroAddress();
        }
        if (amount == 0) revert ZeroAmount();
        if (!lzBridge.supportedTokens(l1Token)) revert UnsupportedToken();

        SafeTransferLib.safeTransferFrom(
            l1Token, msg.sender, address(this), amount
        );
        SafeTransferLib.safeApprove(l1Token, address(lzBridge), amount);

        address sickle = _bridgeAndComputeSickle(l1Token, amount, sickleOwner, adapterParams);

        _emitDepositSent(
            l1Token,
            etherlinkToken,
            sickleOwner,
            intentId,
            amount,
            deadline,
            sickle,
            abi.encode(params),
            signature
        );
    }

    /// @dev Split out from `bridgeDeposit` to keep the outer function
    /// under the EVM stack limit. The `paramsBlob` is pre-encoded by the
    /// caller so this helper takes plain `bytes memory` rather than the
    /// calldata struct, freeing a stack slot.
    function _emitDepositSent(
        address l1Token,
        address etherlinkToken,
        address sickleOwner,
        bytes32 intentId,
        uint256 amount,
        uint256 deadline,
        address sickle,
        bytes memory paramsBlob,
        bytes calldata signature
    ) private {
        emit EtherlinkLzDepositSent(
            destChainId,
            sickleOwner,
            intentId,
            l1Token,
            etherlinkToken,
            amount,
            deadline,
            sickle,
            paramsBlob,
            signature
        );
    }

    /// @dev Split out from `bridgeDeposit` to keep the outer function under
    /// the EVM stack limit. Predicts the destination Sickle, posts the LZ
    /// message, and returns the Sickle address for the emitted event.
    function _bridgeAndComputeSickle(
        address l1Token,
        uint256 amount,
        address sickleOwner,
        bytes calldata adapterParams
    ) private returns (address sickle) {
        sickle = predictDestinationSickle(sickleOwner);
        lzBridge.bridge{ value: msg.value }(
            l1Token,
            amount,
            sickle,
            IOriginalTokenBridge.CallParams({
                refundAddress: payable(msg.sender),
                zroPaymentAddress: address(0)
            }),
            adapterParams
        );
    }
}
