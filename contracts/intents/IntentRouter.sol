// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Admin } from "contracts/base/Admin.sol";
import { IntentTypes } from "./IntentTypes.sol";
import { IIntentRouter } from "./IIntentRouter.sol";
import { ISettlementVerifier } from "./ISettlementVerifier.sol";

/// @title IntentRouter
/// @author vfat.tools
/// @notice Origin-chain escrow contract for user-visible cross-chain intents.
/// Funds are held until either the configured settlement verifier accepts a
/// solver fill or the refund window opens and the user reclaims them.
contract IntentRouter is Admin, IIntentRouter {
    error UnauthorizedCancel();
    error InvalidRouteHash();
    error InvalidRefundDelay();
    error InvalidExclusivityDeadline();
    error InvalidSettlement();
    error InvalidSettlementVerifier();
    error NotGuardianOrAdmin();
    error IntentSubmissionPaused();
    error SettlementPaused();
    error RouteNotAllowed();
    error InputAmountAboveCap(uint256 maxAmount);
    error InputAmountMismatch(uint256 received, uint256 expected);

    event SettlementVerifierSet(address oldVerifier, address newVerifier);
    event GuardianSet(address oldGuardian, address newGuardian);
    event IntentSubmissionPausedSet(bool paused);
    event SettlementPausedSet(bool paused);
    event RouteAllowlistEnabledSet(bool enabled);
    event AllowedRouteHashSet(bytes32 routeHash, bool allowed);
    event InputCapSet(address indexed token, uint256 maxAmount);

    ISettlementVerifier public settlementVerifier;
    address public guardian;
    bool public intentSubmissionPaused;
    bool public settlementPaused;
    bool public routeAllowlistEnabled;

    mapping(bytes32 => bool) public allowedRouteHashes;
    mapping(address => uint256) public maxInputAmountByToken;

    mapping(bytes32 => IntentTypes.Intent) internal _intents;
    mapping(bytes32 => IntentTypes.IntentState) internal _intentStates;

    constructor(
        address admin_,
        address guardian_,
        address settlementVerifier_
    ) Admin(admin_) {
        if (settlementVerifier_ == address(0)) {
            revert InvalidSettlementVerifier();
        }
        guardian = guardian_;
        settlementVerifier = ISettlementVerifier(settlementVerifier_);
        emit GuardianSet(address(0), guardian_);
        emit SettlementVerifierSet(address(0), settlementVerifier_);
    }

    function setSettlementVerifier(
        address newVerifier
    ) external onlyAdmin {
        if (newVerifier == address(0)) revert InvalidSettlementVerifier();
        emit SettlementVerifierSet(address(settlementVerifier), newVerifier);
        settlementVerifier = ISettlementVerifier(newVerifier);
    }

    function setGuardian(
        address newGuardian
    ) external onlyAdmin {
        emit GuardianSet(guardian, newGuardian);
        guardian = newGuardian;
    }

    function pauseIntentSubmission() external {
        _requireGuardianOrAdmin();
        if (intentSubmissionPaused) return;
        intentSubmissionPaused = true;
        emit IntentSubmissionPausedSet(true);
    }

    function unpauseIntentSubmission() external onlyAdmin {
        if (!intentSubmissionPaused) return;
        intentSubmissionPaused = false;
        emit IntentSubmissionPausedSet(false);
    }

    function pauseSettlement() external {
        _requireGuardianOrAdmin();
        if (settlementPaused) return;
        settlementPaused = true;
        emit SettlementPausedSet(true);
    }

    function unpauseSettlement() external onlyAdmin {
        if (!settlementPaused) return;
        settlementPaused = false;
        emit SettlementPausedSet(false);
    }

    function setRouteAllowlistEnabled(
        bool enabled
    ) external onlyAdmin {
        if (routeAllowlistEnabled == enabled) return;
        routeAllowlistEnabled = enabled;
        emit RouteAllowlistEnabledSet(enabled);
    }

    function setAllowedRouteHash(
        bytes32 routeHash,
        bool allowed
    ) external onlyAdmin {
        if (routeHash == bytes32(0)) revert InvalidRouteHash();
        allowedRouteHashes[routeHash] = allowed;
        emit AllowedRouteHashSet(routeHash, allowed);
    }

    function setInputCap(
        address token,
        uint256 maxAmount
    ) external onlyAdmin {
        maxInputAmountByToken[token] = maxAmount;
        emit InputCapSet(token, maxAmount);
    }

    function submitIntent(
        IntentTypes.Intent calldata intent
    ) external payable returns (bytes32 intentId) {
        _requireIntentSubmissionOpen();
        _validateIntent(intent);

        intentId = computeIntentId(intent);
        if (_intentStates[intentId] != IntentTypes.IntentState.None) {
            revert IntentAlreadyExists();
        }

        _intentStates[intentId] = IntentTypes.IntentState.Submitted;
        _intents[intentId] = intent;

        _pullFunds(intent.input.token, intent.input.amount);

        emit IntentSubmitted(
            intentId,
            intent.owner,
            intent.input.token,
            intent.input.amount,
            intent.output.chainId,
            intent.output.token,
            intent.output.recipient,
            intent.execution.mode,
            intent.solver.exclusiveSolver,
            intent.fillDeadline,
            intent.solver.routeHash
        );
    }

    function cancelExpiredIntent(
        bytes32 intentId
    ) external {
        IntentTypes.Intent storage intent = _requireSubmitted(intentId);
        address refundRecipient = intent.execution.refundAddress;

        if (msg.sender != intent.owner && msg.sender != refundRecipient) {
            revert UnauthorizedCancel();
        }

        if (block.timestamp <= intent.fillDeadline + intent.refundDelay) {
            revert IntentNotRefundable();
        }

        _intentStates[intentId] = IntentTypes.IntentState.Cancelled;
        emit IntentCancelled(intentId, intent.owner);

        _intentStates[intentId] = IntentTypes.IntentState.Refunded;
        _payout(intent.input.token, refundRecipient, intent.input.amount);

        emit IntentRefunded(
            intentId, refundRecipient, intent.input.token, intent.input.amount
        );
    }

    function submitSettlement(
        IntentTypes.Settlement calldata settlement
    ) external {
        _requireSettlementOpen();
        IntentTypes.Intent storage intent =
            _requireSubmitted(settlement.intentId);

        if (block.timestamp > intent.fillDeadline + intent.refundDelay) {
            revert IntentNotRefundable();
        }

        if (
            settlement.solver == address(0)
                || settlement.deliveredToken == address(0)
                || settlement.deliveredAmount < intent.output.minAmount
                || settlement.routeHash == bytes32(0)
                || settlement.executionHash == bytes32(0)
        ) {
            revert InvalidSettlement();
        }

        if (settlement.routeHash != intent.solver.routeHash) {
            revert InvalidRouteHash();
        }

        if (settlement.deliveredToken != intent.output.token) {
            revert InvalidSettlement();
        }

        if (
            intent.solver.exclusivityDeadline != 0
                && block.timestamp <= intent.solver.exclusivityDeadline
                && settlement.solver != intent.solver.exclusiveSolver
        ) {
            revert ExclusiveSolverOnly();
        }

        if (
            intent.execution.mode == IntentTypes.ExecutionMode.Strict
                && settlement.fallbackUsed
        ) {
            revert InvalidSettlement();
        }

        settlementVerifier.verifySettlement(address(this), intent, settlement);

        _intentStates[settlement.intentId] = IntentTypes.IntentState.Settled;
        _payout(intent.input.token, settlement.solver, intent.input.amount);

        emit IntentSettled(
            settlement.intentId,
            settlement.solver,
            settlement.routeHash,
            settlement.deliveredToken,
            settlement.deliveredAmount,
            settlement.fallbackUsed,
            settlement.executionHash
        );
    }

    function getIntent(
        bytes32 intentId
    )
        external
        view
        returns (
            IntentTypes.Intent memory intent,
            IntentTypes.IntentState state
        )
    {
        intent = _intents[intentId];
        state = _intentStates[intentId];
    }

    function computeIntentId(
        IntentTypes.Intent calldata intent
    ) public view returns (bytes32) {
        bytes32 inputHash =
            keccak256(abi.encode(intent.input.token, intent.input.amount));
        bytes32 outputHash = keccak256(
            abi.encode(
                intent.output.chainId,
                intent.output.token,
                intent.output.minAmount,
                intent.output.recipient
            )
        );
        bytes32 solverHash = keccak256(
            abi.encode(
                intent.solver.exclusiveSolver,
                intent.solver.exclusivityDeadline,
                intent.solver.routeHash
            )
        );
        bytes32 executionHash = keccak256(
            abi.encode(
                intent.execution.mode,
                intent.execution.refundAddress,
                keccak256(intent.execution.finalAction)
            )
        );

        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                intent.owner,
                intent.nonce,
                inputHash,
                outputHash,
                solverHash,
                executionHash,
                intent.fillDeadline,
                intent.refundDelay
            )
        );
    }

    function _validateIntent(
        IntentTypes.Intent calldata intent
    ) internal view {
        if (intent.owner != msg.sender) revert InvalidAddress();
        if (intent.input.amount == 0 || intent.output.minAmount == 0) {
            revert InvalidAmount();
        }
        if (
            intent.input.token == address(0) && msg.value != intent.input.amount
        ) {
            revert InvalidAmount();
        }
        if (intent.input.token != address(0) && msg.value != 0) {
            revert InvalidAmount();
        }
        if (
            intent.output.chainId == 0 || intent.output.chainId == block.chainid
        ) {
            revert InvalidDestinationChain();
        }
        if (
            intent.output.token == address(0)
                || intent.output.recipient == address(0)
                || intent.execution.refundAddress == address(0)
        ) {
            revert InvalidAddress();
        }
        if (intent.solver.routeHash == bytes32(0)) revert InvalidRouteHash();
        if (
            routeAllowlistEnabled
                && !allowedRouteHashes[intent.solver.routeHash]
        ) {
            revert RouteNotAllowed();
        }
        uint256 maxAmount = maxInputAmountByToken[intent.input.token];
        if (maxAmount != 0 && intent.input.amount > maxAmount) {
            revert InputAmountAboveCap(maxAmount);
        }
        if (intent.refundDelay == 0) revert InvalidRefundDelay();
        if (intent.refundDelay > type(uint256).max - intent.fillDeadline) {
            revert InvalidRefundDelay();
        }
        if (intent.fillDeadline <= block.timestamp) revert InvalidDeadline();
        if (
            intent.solver.exclusivityDeadline != 0
                && (intent.solver.exclusiveSolver == address(0)
                    || intent.solver.exclusivityDeadline > intent.fillDeadline)
        ) {
            revert InvalidExclusivityDeadline();
        }
    }

    function _requireSubmitted(
        bytes32 intentId
    ) internal view returns (IntentTypes.Intent storage intent) {
        if (_intentStates[intentId] != IntentTypes.IntentState.Submitted) {
            revert IntentNotFound();
        }
        intent = _intents[intentId];
    }

    function _pullFunds(
        address token,
        uint256 amount
    ) internal {
        if (token == address(0)) return;
        // Measure actual received escrow and revert on mismatch. The stored
        // intent amount is later paid out verbatim on refund/settlement, so a
        // fee-on-transfer or short-transfer token that delivers less than the
        // nominal amount would render the router insolvent against its own
        // bookkeeping.
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(
            token, msg.sender, address(this), amount
        );
        uint256 received =
            IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) {
            revert InputAmountMismatch(received, amount);
        }
    }

    function _payout(
        address token,
        address to,
        uint256 amount
    ) internal {
        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }

    function _requireGuardianOrAdmin() internal view {
        if (msg.sender != guardian && msg.sender != admin) {
            revert NotGuardianOrAdmin();
        }
    }

    function _requireIntentSubmissionOpen() internal view {
        if (intentSubmissionPaused) revert IntentSubmissionPaused();
    }

    function _requireSettlementOpen() internal view {
        if (settlementPaused) revert SettlementPaused();
    }

    receive() external payable { }
}
