// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";
import {
    IBridgeAmountAdapter
} from "contracts/interfaces/IBridgeAmountAdapter.sol";
import { IRouterAllowlist } from "contracts/interfaces/IRouterAllowlist.sol";
import { SwapRouter } from "contracts/SwapRouter.sol";
import { SwapStep } from "contracts/dex/SwapTypes.sol";

/// @title BridgeRouter
/// @notice Executes source-chain bridge calls, optionally after an MSR swap.
/// @dev Keeps bridge entrypoints out of `SwapRouter`. Source swaps are
/// composed through the deployed swap-only MSR instead of inheriting its full
/// public ABI or embedding its DEX execution code.
contract BridgeRouter is ReentrancyGuard {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IRouterAllowlist public immutable allowlist;
    SwapRouter public swapRouter;

    address public admin;

    error BridgeFailed(bytes error);
    error BridgeDidNotConsumeTokens();
    error InsufficientEthInput();
    error InsufficientOutputAmount(uint256 received, uint256 minRequired);
    error Expired();
    error InvalidAddress();
    error InvalidStepsLength();
    error InvalidTokenPath();
    error NotAdmin();

    /// @dev `feeAmount` is reported by `SwapRouter.swapWithFee` on the
    /// swap output.
    event SwapAndBridge(
        address indexed sender,
        address indexed bridgeToken,
        address indexed bridgeAdapter,
        uint256 amountIn,
        uint256 bridgeAmount,
        uint256 feeAmount
    );

    /// @dev `feeAmount` is charged by BridgeRouter using the current MSR fee
    /// bps.
    event Bridge(
        address indexed sender,
        address indexed bridgeToken,
        address indexed bridgeAdapter,
        uint256 amountIn,
        uint256 bridgeAmount,
        uint256 feeAmount
    );

    event Sweep(address indexed token, uint256 amount);
    event AdminUpdated(address oldAdmin, address newAdmin);
    event SwapRouterUpdated(
        address oldSwapRouter, address newSwapRouter
    );

    struct SwapBridgeEventData {
        address sender;
        address bridgeToken;
        address bridgeAdapter;
        uint256 amountIn;
    }

    struct BridgeContext {
        address bridgeAdapter;
        address bridgeToken;
        bytes bridgeParams;
        address recipient;
        uint256 bridgeAmount;
        uint256 bridgeNativeValue;
        uint256 initialBridgeTokenBalance;
        uint256 preCallEthBalance;
    }

    constructor(
        address allowlist_,
        address swapRouter_,
        address admin_
    ) {
        if (allowlist_ == address(0)) revert InvalidAddress();
        if (swapRouter_ == address(0)) revert InvalidAddress();
        if (admin_ == address(0)) revert InvalidAddress();

        allowlist = IRouterAllowlist(allowlist_);
        _validateSwapRouter(swapRouter_);
        swapRouter = SwapRouter(payable(swapRouter_));
        admin = admin_;
    }

    /// @notice Execute a source swap followed by an exact-amount bridge
    /// adapter.
    /// @dev The adapter receives the actual post-fee bridgeToken amount at
    /// runtime. Native bridge tokens require a swap step that emits native
    /// ETH, such as UnwrapWETH. Use `bridge()` when the user already holds the
    /// bridgeable token.
    function swapAndBridge(
        SwapStep[] calldata steps,
        uint256 amountIn,
        uint256 minSwapOut,
        address bridgeAdapter,
        bytes calldata bridgeParams,
        address bridgeToken,
        address recipient,
        uint256 deadline
    ) external payable nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        if (steps.length == 0) revert InvalidStepsLength();
        _validateBridgeAdapter(bridgeAdapter);

        _swapAndBridge(
            msg.sender,
            steps,
            amountIn,
            minSwapOut,
            bridgeAdapter,
            bridgeParams,
            bridgeToken,
            recipient,
            deadline
        );
    }

    function _swapAndBridge(
        address sender,
        SwapStep[] calldata steps,
        uint256 amountIn,
        uint256 minSwapOut,
        address bridgeAdapter,
        bytes calldata bridgeParams,
        address bridgeToken,
        address recipient,
        uint256 deadline
    ) internal {
        SwapBridgeEventData memory eventData = SwapBridgeEventData({
            sender: sender,
            bridgeToken: bridgeToken,
            bridgeAdapter: bridgeAdapter,
            amountIn: amountIn
        });

        uint256 preCallEthBalance = address(this).balance - msg.value;
        (uint256 bridgeNativeValue, uint256 fee, uint256 initialBalance) = _prepareBridgeAmount(
            steps, amountIn, minSwapOut, bridgeToken, deadline, recipient
        );

        BridgeContext memory bridgeContext = BridgeContext({
            bridgeAdapter: bridgeAdapter,
            bridgeToken: bridgeToken,
            bridgeParams: bridgeParams,
            recipient: recipient,
            bridgeAmount: _balanceOf(bridgeToken) - initialBalance,
            bridgeNativeValue: bridgeNativeValue,
            initialBridgeTokenBalance: initialBalance,
            preCallEthBalance: preCallEthBalance
        });
        if (bridgeContext.bridgeAmount < minSwapOut) {
            revert InsufficientOutputAmount(
                bridgeContext.bridgeAmount, minSwapOut
            );
        }

        uint256 consumed = _executeBridgeAndRefund(bridgeContext);

        _emitSwapAndBridge(eventData, consumed, fee);
    }

    /// @notice Bridge tokens cross-chain through an exact-amount adapter
    /// without any source swap.
    function bridge(
        address bridgeAdapter,
        bytes calldata bridgeParams,
        address bridgeToken,
        uint256 amountIn,
        address recipient,
        uint256 deadline
    ) external payable nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        _validateBridgeAdapter(bridgeAdapter);

        uint256 preCallEthBalance = address(this).balance - msg.value;
        (uint256 bridgeNativeValue, uint256 fee, uint256 initialBalance) =
            _pullDirectBridgeAmount(bridgeToken, amountIn, preCallEthBalance);

        uint256 consumed = _executeBridgeAndRefund(
            BridgeContext({
                bridgeAdapter: bridgeAdapter,
                bridgeToken: bridgeToken,
                bridgeParams: bridgeParams,
                recipient: recipient,
                bridgeAmount: _balanceOf(bridgeToken) - initialBalance,
                bridgeNativeValue: bridgeNativeValue,
                initialBridgeTokenBalance: initialBalance,
                preCallEthBalance: preCallEthBalance
            })
        );

        emit Bridge(
            msg.sender, bridgeToken, bridgeAdapter, amountIn, consumed, fee
        );
    }

    /// @notice Sweep stuck ERC20 tokens to MSR's fee collector.
    function sweep(
        address token
    ) external {
        if (msg.sender != admin) revert NotAdmin();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            // Bridge sweeps use the current MSR fee collector; changing MSR
            // also changes the future sweep destination.
            SafeTransferLib.safeTransfer(
                token, swapRouter.feeCollector(), balance
            );
            emit Sweep(token, balance);
        }
    }

    /// @notice Sweep stuck ETH to MSR's fee collector.
    function sweepETH() external {
        if (msg.sender != admin) revert NotAdmin();
        uint256 balance = address(this).balance;
        if (balance > 0) {
            // Bridge sweeps use the current MSR fee collector; changing MSR
            // also changes the future sweep destination.
            SafeTransferLib.safeTransferETH(
                swapRouter.feeCollector(), balance
            );
            emit Sweep(address(0), balance);
        }
    }

    /// @notice Set a new admin.
    function setAdmin(
        address newAdmin
    ) external {
        if (msg.sender != admin) revert NotAdmin();
        if (newAdmin == address(0)) revert InvalidAddress();
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Point source swaps at a newly deployed swap-only MSR.
    /// @dev Admin can redirect all future `swapAndBridge` source-swap
    /// execution; treat this with the same trust model as other governed
    /// router updates.
    function setSwapRouter(
        address newSwapRouter
    ) external {
        if (msg.sender != admin) revert NotAdmin();
        _validateSwapRouter(newSwapRouter);
        address oldSwapRouter = address(swapRouter);
        if (newSwapRouter == oldSwapRouter) return;
        swapRouter = SwapRouter(payable(newSwapRouter));
        emit SwapRouterUpdated(oldSwapRouter, newSwapRouter);
    }

    function _prepareBridgeAmount(
        SwapStep[] calldata steps,
        uint256 amountIn,
        uint256 minSwapOut,
        address bridgeToken,
        uint256 deadline,
        address residualRecipient
    )
        internal
        returns (uint256 bridgeNativeValue, uint256 fee, uint256 initialBalance)
    {
        // Caller guarantees at least one swap step.
        if (steps[steps.length - 1].tokenOut != bridgeToken) {
            revert InvalidTokenPath();
        }

        bool isNativeInput = steps[0].tokenIn == address(0);
        if (isNativeInput && msg.value < amountIn) {
            revert InsufficientEthInput();
        }

        initialBalance = _balanceOf(bridgeToken);
        if (isNativeInput && bridgeToken == address(0)) {
            initialBalance -= amountIn;
        }
        (bridgeNativeValue, fee) = _executeSourceSwap(
            steps, amountIn, minSwapOut, deadline, bridgeToken, residualRecipient
        );
    }

    function _executeSourceSwap(
        SwapStep[] calldata steps,
        uint256 amountIn,
        uint256 minSwapOut,
        uint256 deadline,
        address bridgeToken,
        address residualRecipient
    ) internal returns (uint256 bridgeNativeValue, uint256 fee) {
        address tokenIn = steps[0].tokenIn;
        // Snapshot the MSR pointer so one bridge flow cannot observe two
        // different MSR deployments.
        SwapRouter currentMsr = swapRouter;
        if (tokenIn == address(0)) {
            bridgeNativeValue = msg.value - amountIn;
            (, fee) = currentMsr.swapWithFee{ value: amountIn }(
                steps, amountIn, minSwapOut, address(this), deadline
            );
        } else {
            bridgeNativeValue = msg.value;
            uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
            SafeTransferLib.safeTransferFrom(
                tokenIn, msg.sender, address(this), amountIn
            );
            uint256 actualInput =
                IERC20(tokenIn).balanceOf(address(this)) - balanceBefore;

            _approve(tokenIn, address(currentMsr), actualInput);
            (, fee) = currentMsr.swapWithFee(
                steps, actualInput, minSwapOut, address(this), deadline
            );
            _revokeApproval(tokenIn, address(currentMsr));

            if (tokenIn != bridgeToken) {
                _refundTokenSurplus(tokenIn, residualRecipient, balanceBefore);
            }
        }
    }

    function _emitSwapAndBridge(
        SwapBridgeEventData memory eventData,
        uint256 consumed,
        uint256 fee
    ) private {
        emit SwapAndBridge(
            eventData.sender,
            eventData.bridgeToken,
            eventData.bridgeAdapter,
            eventData.amountIn,
            consumed,
            fee
        );
    }

    function _pullDirectBridgeAmount(
        address bridgeToken,
        uint256 amountIn,
        uint256 preCallEthBalance
    )
        internal
        returns (uint256 bridgeNativeValue, uint256 fee, uint256 initialBalance)
    {
        bool isNativeBridge = bridgeToken == address(0);
        SwapRouter currentMsr = swapRouter;
        uint256 feeBps = currentMsr.feeBps();
        address feeCollector = currentMsr.feeCollector();

        if (isNativeBridge) {
            if (msg.value < amountIn) revert InsufficientEthInput();
            bridgeNativeValue = msg.value - amountIn;
            initialBalance = preCallEthBalance + bridgeNativeValue;
            // Native input has no fee-on-transfer behavior to net out.
            fee = (amountIn * feeBps) / BPS_DENOMINATOR;
            if (fee > 0) {
                SafeTransferLib.safeTransferETH(feeCollector, fee);
            }
        } else {
            bridgeNativeValue = msg.value;
            initialBalance = IERC20(bridgeToken).balanceOf(address(this));

            SafeTransferLib.safeTransferFrom(
                bridgeToken, msg.sender, address(this), amountIn
            );

            uint256 amountReceived =
                IERC20(bridgeToken).balanceOf(address(this)) - initialBalance;
            fee = (amountReceived * feeBps) / BPS_DENOMINATOR;
            if (fee > 0) {
                SafeTransferLib.safeTransfer(bridgeToken, feeCollector, fee);
            }
        }
    }

    function _executeBridgeAndRefund(
        BridgeContext memory context
    ) internal returns (uint256 consumed) {
        bool isNativeBridge = context.bridgeToken == address(0);
        uint256 balanceBeforeBridge = _balanceOf(context.bridgeToken);

        if (!isNativeBridge) {
            _approve(
                context.bridgeToken, context.bridgeAdapter, context.bridgeAmount
            );
        }

        {
            uint256 callValue = isNativeBridge
                ? context.bridgeNativeValue + context.bridgeAmount
                : context.bridgeNativeValue;
            bytes memory adapterCalldata = abi.encodeCall(
                IBridgeAmountAdapter.bridgeExactAmount,
                (
                    context.bridgeToken,
                    context.bridgeAmount,
                    context.bridgeParams
                )
            );
            (bool success, bytes memory result) =
                context.bridgeAdapter.call{ value: callValue }(adapterCalldata);
            if (!success) revert BridgeFailed(result);
        }

        uint256 balanceAfterBridge = _balanceOf(context.bridgeToken);

        // `>=` catches both over-refund and exact-refund/no-consumption paths
        // before the balance-delta subtraction below.
        if (balanceAfterBridge >= balanceBeforeBridge) {
            revert BridgeDidNotConsumeTokens();
        }
        uint256 consumedBalance = balanceBeforeBridge - balanceAfterBridge;
        if (isNativeBridge) {
            // The bridge call also forwards `bridgeNativeValue` as the
            // relay fee. Require the adapter to consume the full
            // `bridgeAmount + bridgeNativeValue` so a retained relay fee
            // cannot mask under-consumption of the principal — adapters
            // that refund any portion of the relay fee must be priced
            // exactly by the caller.
            if (
                consumedBalance < context.bridgeAmount + context.bridgeNativeValue
            ) {
                revert BridgeDidNotConsumeTokens();
            }
            consumed = context.bridgeAmount;
        } else {
            consumed = consumedBalance;
        }
        if (consumed == 0) {
            revert BridgeDidNotConsumeTokens();
        }

        if (!isNativeBridge) {
            _revokeApproval(context.bridgeToken, context.bridgeAdapter);

            if (balanceAfterBridge > context.initialBridgeTokenBalance) {
                SafeTransferLib.safeTransfer(
                    context.bridgeToken,
                    context.recipient,
                    balanceAfterBridge - context.initialBridgeTokenBalance
                );
            }
        }

        uint256 ethBalance = address(this).balance;
        if (ethBalance > context.preCallEthBalance) {
            SafeTransferLib.safeTransferETH(
                context.recipient, ethBalance - context.preCallEthBalance
            );
        }
    }

    function _refundTokenSurplus(
        address token,
        address recipient,
        uint256 baseBalance
    ) internal {
        uint256 currentBalance = IERC20(token).balanceOf(address(this));
        if (currentBalance <= baseBalance) return;
        SafeTransferLib.safeTransfer(
            token, recipient, currentBalance - baseBalance
        );
    }

    function _validateBridgeAdapter(
        address bridgeAdapter
    ) internal view {
        allowlist.requireAllowedBridge(bridgeAdapter);
        allowlist.requireAllowedSelector(
            bridgeAdapter, IBridgeAmountAdapter.bridgeExactAmount.selector
        );
    }

    function _validateSwapRouter(
        address router
    ) internal view {
        if (router == address(0)) revert InvalidAddress();
        // Hygiene only: admin must still choose a trusted MSR implementation.
        if (SwapRouter(payable(router)).feeCollector() == address(this)) {
            revert InvalidAddress();
        }
    }

    function _balanceOf(
        address token
    ) internal view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        }
        return IERC20(token).balanceOf(address(this));
    }

    function _approve(
        address token,
        address spender,
        uint256 amount
    ) internal {
        SafeTransferLib.safeApprove(token, spender, 0);
        SafeTransferLib.safeApprove(token, spender, amount);
    }

    function _revokeApproval(
        address token,
        address spender
    ) internal {
        SafeTransferLib.safeApprove(token, spender, 0);
    }

    receive() external payable { }
}
