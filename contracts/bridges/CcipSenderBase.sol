// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { GuardianAdmin } from "contracts/base/GuardianAdmin.sol";
import {
    CcipClient,
    ICCIPRouterClient
} from "contracts/interfaces/external/chainlink/ICCIPRouterClient.sol";

/// @title CcipSenderBase
/// @notice Shared source-side helper for Chainlink CCIP token + message
/// sends. `_bridgeMessage` builds either a 1-token or 2-token message
/// depending on whether `forwardAmount > 0`. The 2-token shape is used by
/// `CcipRouteSender` to forward an ERC20 fee token (e.g. CCIP-LINK) to the
/// destination `BridgeRouteReceiver` for the second-hop fee, and by the
/// swap/deposit gas-drop entrypoints to forward destination WETH as
/// callback-chain native gas.
abstract contract CcipSenderBase is GuardianAdmin {
    error ZeroAddress();
    error ZeroAmountReceived();
    error IncorrectNativeFee(uint256 supplied, uint256 required);
    error UnexpectedNativeValue(uint256 supplied);
    error PausedError();
    error DuplicateForwardToken();
    error ExactAmountNonNativeFeeUnsupported();

    event PausedSet(bool paused);

    ICCIPRouterClient public immutable router;
    uint64 public immutable destinationChainSelector;
    address public immutable destinationReceiver;

    bool public paused;

    /// @dev Inherit `GuardianAdmin` (which already provides `guardian`,
    /// `setGuardian`, `GuardianSet`, and `onlyGuardianOrAdmin`) instead of
    /// re-implementing them locally. The canonical guardian surface is now
    /// shared with every other bridge / adapter contract.
    constructor(
        address router_,
        uint64 destinationChainSelector_,
        address destinationReceiver_,
        address admin_,
        address guardian_
    ) GuardianAdmin(admin_, guardian_) {
        if (router_ == address(0) || destinationReceiver_ == address(0)) {
            revert ZeroAddress();
        }
        router = ICCIPRouterClient(router_);
        destinationChainSelector = destinationChainSelector_;
        destinationReceiver = destinationReceiver_;
    }

    function pause() external onlyGuardianOrAdmin {
        if (paused) return;
        paused = true;
        emit PausedSet(true);
    }

    function unpause() external onlyAdmin {
        if (!paused) return;
        paused = false;
        emit PausedSet(false);
    }

    function _getFeeForMessage(
        address token,
        uint256 amount,
        address feeToken,
        bytes memory extraArgs,
        bytes memory data
    ) internal view returns (uint256 fee) {
        return _getFeeForMessage(
            token, amount, address(0), 0, feeToken, extraArgs, data
        );
    }

    function _getFeeForMessage(
        address token,
        uint256 amount,
        address forwardToken,
        uint256 forwardAmount,
        address feeToken,
        bytes memory extraArgs,
        bytes memory data
    ) internal view returns (uint256 fee) {
        // Mirror `_bridgeMessage`'s dual-token preconditions so SDKs do not
        // get a usable-looking quote for a request that `bridgeRoute`
        // would always reject.
        _requireValidForwardToken(token, forwardToken, forwardAmount, feeToken);
        CcipClient.EVM2AnyMessage memory message = _buildMessage(
            token,
            amount,
            forwardToken,
            forwardAmount,
            feeToken,
            extraArgs,
            data
        );
        fee = router.getFee(destinationChainSelector, message);
    }

    function _requireValidForwardToken(
        address token,
        address forwardToken,
        uint256 forwardAmount,
        address feeToken
    ) internal pure {
        if (forwardAmount == 0) return;
        if (forwardToken == address(0)) revert ZeroAddress();
        if (forwardToken == token) revert DuplicateForwardToken();
        if (feeToken == forwardToken) revert DuplicateForwardToken();
    }

    function _requireExactAmountNativeFee(
        address feeToken
    ) internal pure {
        if (feeToken != address(0)) {
            revert ExactAmountNonNativeFeeUnsupported();
        }
    }

    function _bridgeMessage(
        address token,
        uint256 amount,
        address feeToken,
        bytes memory extraArgs,
        bytes memory data
    ) internal returns (bytes32 messageId, uint256 bridgedAmount, uint256 fee) {
        (messageId, bridgedAmount,, fee) = _bridgeMessage(
            token, amount, address(0), 0, feeToken, extraArgs, data
        );
    }

    /// @dev Sends a CCIP token + message. Position [0] in `tokenAmounts` is
    /// the bridge token. When `forwardAmount > 0`, a second `tokenAmount`
    /// (`forwardToken`, e.g. LINK) is included for the destination
    /// `BridgeRouteReceiver` to use as the second-hop fee. `forwardToken`
    /// MUST differ from `token` (and from a non-native CCIP `feeToken`).
    function _bridgeMessage(
        address token,
        uint256 amount,
        address forwardToken,
        uint256 forwardAmount,
        address feeToken,
        bytes memory extraArgs,
        bytes memory data
    )
        internal
        returns (
            bytes32 messageId,
            uint256 bridgedAmount,
            uint256 forwardedAmount,
            uint256 fee
        )
    {
        _requireNotPaused();

        bridgedAmount = _pullAvailable(token, amount);
        if (bridgedAmount == 0) revert ZeroAmountReceived();

        _requireValidForwardToken(token, forwardToken, forwardAmount, feeToken);
        if (forwardAmount > 0) {
            forwardedAmount = _pullAvailable(forwardToken, forwardAmount);
            if (forwardedAmount == 0) revert ZeroAmountReceived();
        }

        CcipClient.EVM2AnyMessage memory message = _buildMessage(
            token,
            bridgedAmount,
            forwardToken,
            forwardedAmount,
            feeToken,
            extraArgs,
            data
        );
        fee = router.getFee(destinationChainSelector, message);

        uint256 nativeValue;
        if (feeToken == address(0)) {
            if (msg.value < fee) revert IncorrectNativeFee(msg.value, fee);
            nativeValue = fee;
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue(msg.value);
            SafeTransferLib.safeTransferFrom(
                feeToken, msg.sender, address(this), fee
            );
        }

        _approveRouter(
            token, bridgedAmount, forwardToken, forwardedAmount, feeToken, fee
        );
        messageId = router.ccipSend{ value: nativeValue }(
            destinationChainSelector, message
        );
        _clearRouterApproval(token, forwardToken, feeToken);

        if (feeToken == address(0) && msg.value > fee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - fee);
        }
    }

    function _buildMessage(
        address token,
        uint256 amount,
        address forwardToken,
        uint256 forwardAmount,
        address feeToken,
        bytes memory extraArgs,
        bytes memory data
    ) internal view returns (CcipClient.EVM2AnyMessage memory message) {
        uint256 count = forwardAmount > 0 ? 2 : 1;
        CcipClient.EVMTokenAmount[] memory tokenAmounts =
            new CcipClient.EVMTokenAmount[](count);
        tokenAmounts[0] =
            CcipClient.EVMTokenAmount({ token: token, amount: amount });
        if (count == 2) {
            tokenAmounts[1] = CcipClient.EVMTokenAmount({
                token: forwardToken, amount: forwardAmount
            });
        }

        message = CcipClient.EVM2AnyMessage({
            receiver: abi.encode(destinationReceiver),
            data: data,
            tokenAmounts: tokenAmounts,
            feeToken: feeToken,
            extraArgs: extraArgs
        });
    }

    function _pullAvailable(
        address token,
        uint256 amount
    ) internal returns (uint256 received) {
        uint256 balanceBefore = _tokenBalance(token);
        SafeTransferLib.safeTransferFrom(
            token, msg.sender, address(this), amount
        );
        uint256 balanceAfter = _tokenBalance(token);
        received = balanceAfter - balanceBefore;
    }

    function _approveRouter(
        address token,
        uint256 tokenAmount,
        address forwardToken,
        uint256 forwardAmount,
        address feeToken,
        uint256 fee
    ) internal {
        address routerAddress = address(router);

        SafeTransferLib.safeApprove(token, routerAddress, 0);
        SafeTransferLib.safeApprove(
            token,
            routerAddress,
            feeToken == token ? tokenAmount + fee : tokenAmount
        );

        if (forwardAmount > 0) {
            SafeTransferLib.safeApprove(forwardToken, routerAddress, 0);
            SafeTransferLib.safeApprove(
                forwardToken, routerAddress, forwardAmount
            );
        }

        // `feeToken == forwardToken` is unreachable here because
        // `_requireValidForwardToken` already
        // rejects that combination whenever `forwardAmount > 0`.
        if (feeToken != address(0) && feeToken != token) {
            SafeTransferLib.safeApprove(feeToken, routerAddress, 0);
            SafeTransferLib.safeApprove(feeToken, routerAddress, fee);
        }
    }

    function _clearRouterApproval(
        address token,
        address forwardToken,
        address feeToken
    ) internal {
        address routerAddress = address(router);
        SafeTransferLib.safeApprove(token, routerAddress, 0);
        if (forwardToken != address(0)) {
            SafeTransferLib.safeApprove(forwardToken, routerAddress, 0);
        }
        // See `_approveRouter` — `feeToken == forwardToken` is already
        // rejected upstream.
        if (feeToken != address(0) && feeToken != token) {
            SafeTransferLib.safeApprove(feeToken, routerAddress, 0);
        }
    }

    function _tokenBalance(
        address token
    ) internal view returns (uint256) {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _requireNotPaused() internal view {
        if (paused) revert PausedError();
    }

    /// @notice Admin rescue for ERC20s mistakenly transferred directly to
    /// this sender. Sender bridge flows snapshot balance before pulling and
    /// only forward the delta, so direct transfers are otherwise stranded
    /// indefinitely.
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyAdmin {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    /// @notice Admin rescue for ETH delivered via the open `receive()`.
    function rescueETH(
        address to,
        uint256 amount
    ) external onlyAdmin {
        SafeTransferLib.safeTransferETH(to, amount);
    }

    receive() external payable { }
}
