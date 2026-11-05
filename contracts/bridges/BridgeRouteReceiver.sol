// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { SwapStep } from "contracts/dex/SwapTypes.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";
import { GuardianAdmin } from "contracts/base/GuardianAdmin.sol";
import { SwapRouter } from "contracts/SwapRouter.sol";
import { IRouterAllowlist } from "contracts/interfaces/IRouterAllowlist.sol";

interface IWETHBridgeRouteReceiver {
    function withdraw(
        uint256
    ) external;
}

/// @title BridgeRouteReceiver
/// @notice Receives bridged tokens from whitelisted adapters, optionally
/// swaps on the intermediate chain, and immediately launches the next bridge
/// hop. Adapters that deliver a single token call `executeRoute` with
/// `(feeToken, feeAmount) = (address(0), 0)`. Adapters that also deliver a
/// fee-forwarding token (e.g. CCIP-LINK packed as a second `tokenAmount` by
/// `CcipRouteSender`) pass the delivered `(feeToken, feeAmount)` so the
/// receiver can approve it to the second-hop bridge for `feeAmount` and
/// refund the unspent leftover to `params.fallbackRecipient`.
///
/// The hub-funded native cap (`maxHubNativeFeeByAdapter`) lets the hub's own
/// ETH balance top up `nextHop.nativeValue` past `msg.value`, bounded by an
/// admin-set per-adapter cap (default zero). Only adapters that paid a
/// comparable source-side fee on the way in (e.g. `CcipRouteAdapter`) should
/// be granted a nonzero cap, otherwise a cheap first-hop adapter could drain
/// the float via an expensive CCIP second hop.
contract BridgeRouteReceiver is GuardianAdmin, ReentrancyGuard {
    error NotWhitelistedAdapter();
    error ZeroAddress();
    error ZeroAmountReceived();
    error OnlySelf();
    error InvalidTokenPath();
    error NativePrincipalNotSupported();
    error FeeTokenConflictsWithRouteToken();
    error InsufficientInputAmount();
    error InsufficientBridgeAmount();
    error BridgeCalldataTooShort();
    error InvalidBridgeAmountOffset();
    error HubNativeFeeExceedsCap(uint256 hubContribution, uint256 cap);
    error BridgeDidNotConsumeTokens();
    error BridgeFailed(bytes reason);
    error NativeGasDropTokenNotWrappedNative();
    error NativeGasDropExceedsAmount();
    error NativeGasDropTokenConflicts();
    error HubFundedSelectorNotRegistered(
        address bridgeContract, bytes4 selector
    );
    error InvalidHubRefundRecipientOffset();
    error HubFundedNativeBridgeUnsupported();
    error WouldConsumeReservedRefund();
    error AdapterNotAContract();
    /// Thrown when calldata targets a (bridgeContract, selector) pair that
    /// does not have an admin-registered route-continuation policy.
    error RouteSelectorNotRegistered(
        address bridgeContract, bytes4 selector
    );
    /// The policy demands an authenticated originator but the adapter passed
    /// `bytes32(0)`, meaning the inbound bridge cannot authenticate its
    /// source-chain sender. Reject; the downstream call would be replayable.
    error MissingAuthenticatedOriginator(
        address bridgeContract, bytes4 selector
    );
    error InvalidOriginatorOffset();

    event BridgeRouteExecuted(
        address indexed fallbackRecipient,
        address indexed tokenIn,
        address indexed bridgeToken,
        uint256 amountIn,
        uint256 bridgeAmount,
        address bridgeContract
    );

    event BridgeRouteFallback(
        address indexed fallbackRecipient, address indexed token, uint256 amount
    );

    /// @notice Emitted when a native refund delivery fails. The unrefunded
    /// `amount` remains in this contract and must be recovered via
    /// `rescueETH`.
    event RefundFailed(address indexed recipient, uint256 amount);

    event WhitelistedAdapterSet(address adapter, bool whitelisted);

    event MaxHubNativeFeeByAdapterSet(
        address indexed adapter, uint256 oldCap, uint256 newCap
    );

    /// @notice Emitted when the route policy for a (bridgeContract,
    /// selector) pair is set.
    event RouteSelectorPolicySet(
        address indexed bridgeContract,
        bytes4 indexed selector,
        bool registered,
        uint256 amountOffset,
        uint256 refundPolicy,
        uint256 originatorOffset
    );

    /// @notice Per-(bridgeContract, selector) route-continuation policy.
    /// Every call through `_validateAndPatchCalldata` must reference a
    /// `registered == true` entry, even when no hub native value is requested.
    /// The user-supplied amount offset is ignored; the admin-pinned
    /// `amountOffset` is used to patch the calldata, which prevents generic
    /// bridge-allowlist entries (e.g. Wormhole executor selectors) from being
    /// misused as route continuations.
    /// `refundPolicy` reuses the encoding introduced in #12:
    ///   - `0`: selector cannot be invoked with hub-funded native value;
    ///     `hubContribution > 0` reverts.
    ///   - `HUB_REFUND_IMPLICIT`: bridge contract refunds unused native
    ///     to `msg.sender` (this receiver) by convention; no patching.
    ///   - any other value: interpreted as the calldata offset of the
    ///     refund recipient field, which is overwritten with
    ///     `address(this)` before the call.
    struct RouteSelectorPolicy {
        bool registered;
        uint256 amountOffset;
        uint256 refundPolicy;
        /// @dev When nonzero, the receiver patches the calldata at this
        /// offset with the authenticated `originator` supplied by the inbound
        /// route adapter (computed from its bridge protocol's source-chain
        /// authentication). The selector must be reached with a nonzero
        /// originator or the call reverts. Set to 0 for selectors whose
        /// downstream call has no originator binding.
        uint256 originatorOffset;
    }

    struct NextHopParams {
        address bridgeContract;
        bytes bridgeCalldata;
        address bridgeToken;
        uint256 minBridgeAmount;
        uint256 nativeValue;
    }

    struct RouteParams {
        address fallbackRecipient;
        uint256 minAmountIn;
        SwapStep[] swapSteps;
        uint256 minSwapOut;
        NextHopParams nextHop;
        /// @dev Native gas to leave for fallbackRecipient on this route
        /// execution chain, often the hub chain rather than the final
        /// destination chain. Denominated in wei. Supported only when the
        /// first-hop delivered token is this chain's wrapped native token.
        /// Route amounts and slippage checks are planned against
        /// `amount - nativeGasDrop`.
        uint256 nativeGasDrop;
        /// @dev Deadline (unix seconds) forwarded to `SwapRouter.swap`
        /// for the intermediate-chain swap. Source-chain senders should
        /// bound how long the destination-side swap can remain executable;
        /// pass `type(uint256).max` to intentionally skip the check.
        uint256 swapDeadline;
    }

    SwapRouter public immutable msr;
    IRouterAllowlist public immutable allowlist;

    mapping(address => bool) public whitelistedAdapters;
    address[] private _adapters;
    mapping(address => uint256) private _adapterIndexPlusOne;

    /// @notice Per-adapter cap on the hub-funded portion of
    /// `nextHop.nativeValue`. The hub-funded portion is
    /// `nativeValue - msg.value` (clamped to zero when
    /// `msg.value >= nativeValue`). Default zero per adapter — admin must
    /// opt in via `setMaxHubNativeFeeByAdapter(adapter, cap)` to let a
    /// specific source-side adapter draw from the hub's own ETH balance.
    /// Only adapters whose source-side path already paid a comparable fee
    /// (e.g. `CcipRouteAdapter`) should be granted a nonzero cap.
    mapping(address adapter => uint256 cap) public maxHubNativeFeeByAdapter;

    /// @notice Admin-set route-continuation policy per (bridgeContract,
    /// selector).
    /// See `RouteSelectorPolicy` for the encoding.
    mapping(address bridgeContract => mapping(bytes4 selector => RouteSelectorPolicy))
        public routeSelectorPolicy;

    /// @notice Sentinel value for `refundPolicy` indicating that the
    /// bridge contract refunds unused native to `msg.sender` (this
    /// receiver) by convention; no calldata patching is required.
    uint256 public constant HUB_REFUND_IMPLICIT = type(uint256).max;

    /// @notice ETH that was supposed to be refunded to a fallbackRecipient
    /// but the refund send failed (non-payable recipient). This is held in
    /// trust until `rescueETH` recovers it, and is **excluded** from the
    /// pool of native value available for hub-funded second-hop fees.
    uint256 public reservedRefundEth;

    constructor(
        address msr_,
        address admin_,
        address guardian_
    ) GuardianAdmin(admin_, guardian_) {
        if (msr_ == address(0)) revert ZeroAddress();
        msr = SwapRouter(payable(msr_));
        allowlist = msr.allowlist();
    }

    function adapters() external view returns (address[] memory) {
        return _adapters;
    }

    function setWhitelistedAdapter(
        address adapter,
        bool whitelisted
    ) external onlyAdmin {
        _setWhitelistedAdapter(adapter, whitelisted);
    }

    /// @notice Emergency-disable an adapter without waiting on governance.
    /// Re-enabling still requires the admin path.
    function emergencyDisableAdapter(
        address adapter
    ) external onlyGuardianOrAdmin {
        _setWhitelistedAdapter(adapter, false);
    }

    function _setWhitelistedAdapter(
        address adapter,
        bool whitelisted
    ) internal {
        // Same-chain adapters must be contracts.
        if (whitelisted && adapter.code.length == 0) {
            revert AdapterNotAContract();
        }
        bool currentlyAllowed = whitelistedAdapters[adapter];
        if (currentlyAllowed == whitelisted) return;

        whitelistedAdapters[adapter] = whitelisted;
        if (whitelisted) {
            _adapterIndexPlusOne[adapter] = _adapters.length + 1;
            _adapters.push(adapter);
        } else {
            uint256 indexPlusOne = _adapterIndexPlusOne[adapter];
            uint256 index = indexPlusOne - 1;
            uint256 lastIndex = _adapters.length - 1;
            if (index != lastIndex) {
                address last = _adapters[lastIndex];
                _adapters[index] = last;
                _adapterIndexPlusOne[last] = index + 1;
            }
            _adapters.pop();
            delete _adapterIndexPlusOne[adapter];
        }
        emit WhitelistedAdapterSet(adapter, whitelisted);
    }

    function setMaxHubNativeFeeByAdapter(
        address adapter,
        uint256 newCap
    ) external onlyAdmin {
        if (adapter == address(0)) revert ZeroAddress();
        uint256 oldCap = maxHubNativeFeeByAdapter[adapter];
        if (oldCap == newCap) return;
        maxHubNativeFeeByAdapter[adapter] = newCap;
        emit MaxHubNativeFeeByAdapterSet(adapter, oldCap, newCap);
    }

    /// @notice Admin-set route-continuation policy for a (bridgeContract,
    /// selector) pair. The
    /// `amountOffset` is admin-pinned: the user-supplied calldata is
    /// patched at this offset, not at one chosen in the route params.
    /// `refundPolicy` follows the encoding documented on
    /// `RouteSelectorPolicy`.
    function setRouteSelectorPolicy(
        address bridgeContract,
        bytes4 selector,
        bool registered,
        uint256 amountOffset,
        uint256 refundPolicy,
        uint256 originatorOffset
    ) external onlyAdmin {
        if (bridgeContract == address(0)) revert ZeroAddress();
        routeSelectorPolicy[bridgeContract][selector] = RouteSelectorPolicy({
            registered: registered,
            amountOffset: amountOffset,
            refundPolicy: refundPolicy,
            originatorOffset: originatorOffset
        });
        emit RouteSelectorPolicySet(
            bridgeContract,
            selector,
            registered,
            amountOffset,
            refundPolicy,
            originatorOffset
        );
    }

    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyAdmin {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    function rescueETH(
        address to,
        uint256 amount
    ) external onlyAdmin {
        // Shrink the reserved refund bucket as admin recovers stranded ETH
        // (typically the intent of `rescueETH`). Excess beyond
        // `reservedRefundEth` dips into legitimate hub float, which is
        // acceptable under explicit admin control.
        uint256 reserved = reservedRefundEth;
        if (reserved > 0) {
            reservedRefundEth = amount >= reserved ? 0 : reserved - amount;
        }
        SafeTransferLib.safeTransferETH(to, amount);
    }

    /// @notice Execute a route hop. Adapters that deliver only the bridged
    /// token pass `(feeToken, feeAmount) = (address(0), 0)`. Adapters that
    /// also deliver a fee-forwarding ERC20 (e.g. CCIP-LINK as a second
    /// `tokenAmount`) pass the delivered amount; the receiver approves it
    /// to the second-hop bridge for `feeAmount` and refunds the unspent
    /// leftover to `params.fallbackRecipient`.
    /// @param originator Authenticated source-chain identifier supplied by
    /// the inbound route adapter (e.g. `keccak256(srcEid, composeFrom)` for
    /// Stargate, `keccak256(srcChainSelector, sender)` for CCIP). Pass
    /// `bytes32(0)` if the inbound bridge has no source-sender authentication;
    /// selectors that require an originator will then revert (their downstream
    /// call would be replayable).
    function executeRoute(
        address token,
        uint256 amount,
        address feeToken,
        uint256 feeAmount,
        bytes32 originator,
        RouteParams calldata params
    ) external payable nonReentrant {
        _onlyWhitelistedAdapter();
        address adapter = msg.sender;
        if (params.fallbackRecipient == address(0)) revert ZeroAddress();
        // Defense in depth: no current adapter delivers native principal
        // (Stargate wraps to WETH, CCIP /
        // Wormhole resolve to ERC20). Accepting `token == address(0)` would
        // let a misconfigured adapter credit the receiver's own ETH float
        // as route principal in the native-bridge branch of
        // `_callBridgeWithApprovals`.
        if (token == address(0)) revert NativePrincipalNotSupported();
        // The fee-token refund baseline is taken as
        // `balanceOf(feeToken) - feeAmount` at entry, which assumes the
        // delivered fee is the only `feeToken` accounted for. A direct
        // collision with the delivered route token cannot be refunded
        // correctly after fallback, so reject it up front. A collision with
        // the next-hop bridge token is checked inside the protected self-call
        // so cross-chain mapped-token routes can fall back cleanly.
        _requireFeeTokenNotRouteToken(token, feeToken, feeAmount);

        uint256 preCallEthBalance = address(this).balance - msg.value;
        uint256 preCallFeeBalance = _preCallTokenBalance(feeToken, feeAmount);

        try this.routeExternal{ value: msg.value }(
            adapter, token, amount, feeToken, feeAmount, originator, params
        ) returns (
            address bridgeToken, uint256 routeAmount, uint256 bridgeAmount
        ) {
            _refundExcessEth(params.fallbackRecipient, preCallEthBalance);
            if (feeToken != address(0)) {
                _refundExcessFeeToken(
                    feeToken, params.fallbackRecipient, preCallFeeBalance
                );
            }
            emit BridgeRouteExecuted(
                params.fallbackRecipient,
                token,
                bridgeToken,
                routeAmount,
                bridgeAmount,
                params.nextHop.bridgeContract
            );
        } catch {
            // Note: `routeExternal` is an external self-call, so any state
            // changes inside it (WETH unwrap, native-gas-drop sends,
            // approvals) revert with it. The catch block sees only the
            // originally-delivered token balance plus `msg.value`.
            uint256 fallbackAmount =
                _transferAvailable(token, params.fallbackRecipient, amount);
            _refundExcessEth(params.fallbackRecipient, preCallEthBalance);
            if (feeToken != address(0)) {
                _refundExcessFeeToken(
                    feeToken, params.fallbackRecipient, preCallFeeBalance
                );
            }
            emit BridgeRouteFallback(
                params.fallbackRecipient, token, fallbackAmount
            );
        }
    }

    /// @notice Execute a route while reserving native gas from a separately
    /// bridged wrapped-native token.
    /// @param nativeGasDropToken Token delivered by the adapter for the gas
    /// drop. Must be this chain's wrapped native token and must differ from
    /// both `token` and `feeToken`; use `RouteParams.nativeGasDrop` for
    /// primary-WETH drops.
    /// @param nativeGasDrop Amount of `nativeGasDropToken` to unwrap and send
    /// to `params.fallbackRecipient`, denominated in wei.
    function executeRouteWithNativeGasDropToken(
        address token,
        uint256 amount,
        address feeToken,
        uint256 feeAmount,
        address nativeGasDropToken,
        uint256 nativeGasDrop,
        bytes32 originator,
        RouteParams calldata params
    ) external payable nonReentrant {
        _onlyWhitelistedAdapter();
        address adapter = msg.sender;
        if (params.fallbackRecipient == address(0)) revert ZeroAddress();
        if (token == address(0)) revert NativePrincipalNotSupported();
        if (nativeGasDrop > 0 && params.nativeGasDrop > 0) {
            revert NativeGasDropTokenConflicts();
        }
        // Enforce the `nativeGasDropToken` independence invariant at the top
        // level, before refund baselines are recorded. The check inside the
        // caught self-call (in `_sendNativeGasDropToken`) was reverting the
        // inner call but landing in the outer fallback path with overlapping
        // baselines, stranding delivered tokens in the receiver until admin
        // rescue.
        if (nativeGasDrop > 0) {
            if (nativeGasDropToken == token
                    || nativeGasDropToken == feeToken) {
                revert NativeGasDropTokenConflicts();
            }
        }
        _requireFeeTokenNotRouteToken(token, feeToken, feeAmount);

        uint256 preCallEthBalance = address(this).balance - msg.value;
        uint256 preCallFeeBalance = _preCallTokenBalance(feeToken, feeAmount);
        uint256 preCallGasDropBalance =
            _preCallTokenBalance(nativeGasDropToken, nativeGasDrop);

        try this.routeWithNativeGasDropTokenExternal{ value: msg.value }(
            adapter,
            token,
            amount,
            feeToken,
            feeAmount,
            nativeGasDropToken,
            nativeGasDrop,
            originator,
            params
        ) returns (
            address bridgeToken, uint256 routeAmount, uint256 bridgeAmount
        ) {
            _refundExcessEth(params.fallbackRecipient, preCallEthBalance);
            if (feeToken != address(0)) {
                _refundExcessFeeToken(
                    feeToken, params.fallbackRecipient, preCallFeeBalance
                );
            }
            if (nativeGasDropToken != address(0)) {
                _refundExcessFeeToken(
                    nativeGasDropToken,
                    params.fallbackRecipient,
                    preCallGasDropBalance
                );
            }
            emit BridgeRouteExecuted(
                params.fallbackRecipient,
                token,
                bridgeToken,
                routeAmount,
                bridgeAmount,
                params.nextHop.bridgeContract
            );
        } catch {
            // See note in `executeRoute`: state inside the external
            // self-call reverts on failure, so no rewrap is possible here.
            uint256 fallbackAmount =
                _transferAvailable(token, params.fallbackRecipient, amount);
            _refundExcessEth(params.fallbackRecipient, preCallEthBalance);
            if (feeToken != address(0)) {
                _refundExcessFeeToken(
                    feeToken, params.fallbackRecipient, preCallFeeBalance
                );
            }
            if (nativeGasDropToken != address(0)) {
                _refundExcessFeeToken(
                    nativeGasDropToken,
                    params.fallbackRecipient,
                    preCallGasDropBalance
                );
            }
            emit BridgeRouteFallback(
                params.fallbackRecipient, token, fallbackAmount
            );
        }
    }

    function routeExternal(
        address adapter,
        address token,
        uint256 amount,
        address feeToken,
        uint256 feeAmount,
        bytes32 originator,
        RouteParams calldata params
    )
        external
        payable
        returns (address bridgeToken, uint256 routeAmount, uint256 bridgeAmount)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        // Defense in depth: the cap is per-adapter, but a zero-amount
        // route with a nonzero cap could still consume hub native float
        // on a no-op second hop. Reject regardless of `params.minAmountIn`,
        // so a future adapter that fails to filter empty deliveries
        // cannot reach `_executeBridge`.
        if (amount == 0) revert ZeroAmountReceived();
        _requireFeeTokenNotBridgeToken(feeToken, feeAmount, params);
        routeAmount = _reserveNativeGasDrop(
            token, amount, params.fallbackRecipient, params.nativeGasDrop
        );
        if (routeAmount < params.minAmountIn) {
            revert InsufficientInputAmount();
        }

        (bridgeToken, bridgeAmount) =
            _resolveBridgeTokenAmount(token, routeAmount, params);

        _executeBridge(
            adapter,
            params.nextHop.bridgeContract,
            params.nextHop.bridgeCalldata,
            bridgeToken,
            bridgeAmount,
            params.nextHop.nativeValue,
            feeToken,
            feeAmount,
            originator
        );
    }

    function routeWithNativeGasDropTokenExternal(
        address adapter,
        address token,
        uint256 amount,
        address feeToken,
        uint256 feeAmount,
        address nativeGasDropToken,
        uint256 nativeGasDrop,
        bytes32 originator,
        RouteParams calldata params
    )
        external
        payable
        returns (address bridgeToken, uint256 routeAmount, uint256 bridgeAmount)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        if (amount == 0) revert ZeroAmountReceived();
        // The `nativeGasDrop > 0 && params.nativeGasDrop > 0` conflict is
        // already enforced upstream in `executeRouteWithNativeGasDropToken`,
        // and this entrypoint is OnlySelf, so the duplicate check is dead.
        _sendNativeGasDropToken(
            nativeGasDropToken, params.fallbackRecipient, nativeGasDrop
        );
        return this.routeExternal{ value: msg.value }(
            adapter, token, amount, feeToken, feeAmount, originator, params
        );
    }

    function _onlyWhitelistedAdapter() internal view {
        if (!whitelistedAdapters[msg.sender]) {
            revert NotWhitelistedAdapter();
        }
    }

    /// @dev Reject same-token fee forwarding shapes that would strand
    /// unspent fee leftovers in the receiver. The fee-refund baseline
    /// uses `balanceOf(feeToken) - feeAmount`, which assumes the only
    /// delivered amount of `feeToken` is the fee itself.
    function _requireFeeTokenNotRouteToken(
        address token,
        address feeToken,
        uint256 feeAmount
    ) internal pure {
        if (feeToken == address(0) || feeAmount == 0) return;
        if (feeToken == token) revert FeeTokenConflictsWithRouteToken();
    }

    function _requireFeeTokenNotBridgeToken(
        address feeToken,
        uint256 feeAmount,
        RouteParams calldata params
    ) internal pure {
        if (feeToken == address(0) || feeAmount == 0) return;
        if (feeToken == params.nextHop.bridgeToken) {
            revert FeeTokenConflictsWithRouteToken();
        }
    }

    function _resolveBridgeTokenAmount(
        address token,
        uint256 amount,
        RouteParams calldata params
    ) internal returns (address bridgeToken, uint256 bridgeAmount) {
        if (params.swapSteps.length == 0) {
            if (token != params.nextHop.bridgeToken) revert InvalidTokenPath();
            bridgeToken = token;
            bridgeAmount = amount;
        } else {
            if (params.swapSteps[0].tokenIn != token) {
                revert InvalidTokenPath();
            }
            if (
                params.swapSteps[params.swapSteps.length - 1].tokenOut
                    != params.nextHop.bridgeToken
            ) {
                revert InvalidTokenPath();
            }
            bridgeToken = params.nextHop.bridgeToken;
            bridgeAmount = _swapToBridgeToken(
                token,
                amount,
                params.swapSteps,
                params.minSwapOut,
                params.swapDeadline,
                params.fallbackRecipient
            );
        }

        if (bridgeAmount < params.nextHop.minBridgeAmount) {
            revert InsufficientBridgeAmount();
        }
    }

    function _swapToBridgeToken(
        address token,
        uint256 amount,
        SwapStep[] calldata swapSteps,
        uint256 minSwapOut,
        uint256 swapDeadline,
        address residualRecipient
    ) internal returns (uint256 amountOut) {
        address bridgeToken = swapSteps[swapSteps.length - 1].tokenOut;
        bool refundInputResidue = token != bridgeToken;
        uint256 residualBaseline;
        if (refundInputResidue) {
            residualBaseline = IERC20(token).balanceOf(address(this)) - amount;
        }

        SafeTransferLib.safeApprove(token, address(msr), 0);
        SafeTransferLib.safeApprove(token, address(msr), amount);
        amountOut = msr.swap(
            swapSteps, amount, minSwapOut, address(this), swapDeadline
        );
        SafeTransferLib.safeApprove(token, address(msr), 0);

        if (refundInputResidue) {
            _refundTokenSurplus(token, residualRecipient, residualBaseline);
        }
    }

    function _executeBridge(
        address adapter,
        address bridgeContract,
        bytes calldata bridgeCalldata,
        address bridgeToken,
        uint256 bridgeAmount,
        uint256 nativeValue,
        address feeToken,
        uint256 feeAmount,
        bytes32 originator
    ) internal {
        // Every route-continuation call must reference an admin-registered
        // route selector policy. The policy supplies the calldata amount
        // offset (the user-supplied offset in the old struct is gone), and
        // gates whether hub-funded native value is permitted.
        uint256 hubContribution =
            msg.value < nativeValue ? nativeValue - msg.value : 0;
        // Native-principal hops settle the principal as msg.value, and the
        // consumption check in _callBridgeWithApprovals requires the full
        // bridgeAmount + nativeValue to be spent (no native refund). That
        // can't coexist with hub funding, which expects unused native back
        // here, so reject it: native hops must be source-funded with an
        // exact fee quote.
        if (bridgeToken == address(0) && hubContribution > 0) {
            revert HubFundedNativeBridgeUnsupported();
        }
        bytes memory patchedCalldata = _validateAndPatchCalldata(
            bridgeContract,
            bridgeCalldata,
            bridgeAmount,
            hubContribution,
            originator
        );
        _checkHubNativeFeeCap(adapter, hubContribution);
        _callBridgeWithApprovals(
            bridgeContract,
            patchedCalldata,
            bridgeToken,
            bridgeAmount,
            nativeValue,
            feeToken,
            feeAmount
        );
    }

    function _reserveNativeGasDrop(
        address token,
        uint256 amount,
        address recipient,
        uint256 nativeGasDrop
    ) internal returns (uint256 routeAmount) {
        if (nativeGasDrop == 0) return amount;
        if (nativeGasDrop >= amount) revert NativeGasDropExceedsAmount();

        address wrappedNative = msr.wrappedNative();
        if (token != wrappedNative) {
            revert NativeGasDropTokenNotWrappedNative();
        }

        IWETHBridgeRouteReceiver(wrappedNative).withdraw(nativeGasDrop);
        SafeTransferLib.safeTransferETH(recipient, nativeGasDrop);

        return amount - nativeGasDrop;
    }

    function _sendNativeGasDropToken(
        address nativeGasDropToken,
        address recipient,
        uint256 nativeGasDrop
    ) internal {
        if (nativeGasDrop == 0) return;

        address wrappedNative = msr.wrappedNative();
        if (nativeGasDropToken != wrappedNative) {
            revert NativeGasDropTokenNotWrappedNative();
        }

        IWETHBridgeRouteReceiver(wrappedNative).withdraw(nativeGasDrop);
        SafeTransferLib.safeTransferETH(recipient, nativeGasDrop);
    }

    function _validateAndPatchCalldata(
        address bridgeContract,
        bytes calldata bridgeCalldata,
        uint256 bridgeAmount,
        uint256 hubContribution,
        bytes32 originator
    ) internal view returns (bytes memory patchedCalldata) {
        allowlist.requireAllowedBridge(bridgeContract);

        patchedCalldata = bridgeCalldata;
        if (patchedCalldata.length < 4) revert BridgeCalldataTooShort();

        bytes4 selector = _selector(patchedCalldata);
        allowlist.requireAllowedSelector(bridgeContract, selector);

        // Require an admin-registered route policy for *any* invocation here.
        // The user does not supply the amount offset — the admin pins it per
        // selector, so dual-use bridge selectors (e.g. Wormhole executor
        // functions) allowlisted for other workflows cannot be repurposed as
        // route continuations.
        RouteSelectorPolicy memory policy =
            routeSelectorPolicy[bridgeContract][selector];
        if (!policy.registered) {
            revert RouteSelectorNotRegistered(bridgeContract, selector);
        }

        uint256 amountOffset = policy.amountOffset;
        if (
            amountOffset < 4 || patchedCalldata.length < 36
                || amountOffset > patchedCalldata.length - 32
        ) {
            revert InvalidBridgeAmountOffset();
        }
        _patchUint256(patchedCalldata, amountOffset, bridgeAmount);

        // Hub-funded calls obey the refund-recipient sub-policy.
        // `refundPolicy == 0` means the selector cannot draw hub native float.
        if (hubContribution > 0) {
            uint256 refundPolicy = policy.refundPolicy;
            if (refundPolicy == 0) {
                revert HubFundedSelectorNotRegistered(
                    bridgeContract, selector
                );
            }
            if (refundPolicy != HUB_REFUND_IMPLICIT) {
                if (
                    refundPolicy < 4 || patchedCalldata.length < 36
                        || refundPolicy > patchedCalldata.length - 32
                ) {
                    revert InvalidHubRefundRecipientOffset();
                }
                _patchUint256(
                    patchedCalldata,
                    refundPolicy,
                    uint256(uint160(address(this)))
                );
            }
        }

        // Selectors that route into an originator-bound downstream call (e.g.
        // Stargate deposits) declare an `originatorOffset`. The receiver
        // overwrites the calldata word at that offset with the
        // adapter-authenticated originator. If the adapter has no source
        // authentication (originator == 0) the call reverts — the downstream
        // signature verification would otherwise treat any user-supplied bytes
        // as authoritative.
        uint256 originatorOffset = policy.originatorOffset;
        if (originatorOffset != 0) {
            if (originator == bytes32(0)) {
                revert MissingAuthenticatedOriginator(
                    bridgeContract, selector
                );
            }
            if (
                originatorOffset < 4 || patchedCalldata.length < 36
                    || originatorOffset > patchedCalldata.length - 32
            ) {
                revert InvalidOriginatorOffset();
            }
            _patchUint256(
                patchedCalldata, originatorOffset, uint256(originator)
            );
        }
    }

    /// @dev Permit the hub's own ETH balance to top up `nativeValue` past
    /// `msg.value`, but only up to the admin-set per-adapter cap. CCIP-shaped
    /// second hops rely on this because `ccipReceive` is non-payable. Hops
    /// that already provide sufficient `msg.value` (Stargate, Across)
    /// pay a `hubContribution` of zero and ignore the cap.
    /// Adapters whose source-side path did not pay a comparable fee (e.g.
    /// Across, DeBridge) default to a zero cap and cannot draw hub float.
    function _checkHubNativeFeeCap(
        address adapter,
        uint256 hubContribution
    ) internal view {
        uint256 cap = maxHubNativeFeeByAdapter[adapter];
        if (hubContribution > cap) {
            revert HubNativeFeeExceedsCap(hubContribution, cap);
        }
    }

    function _callBridgeWithApprovals(
        address bridgeContract,
        bytes memory patchedCalldata,
        address bridgeToken,
        uint256 bridgeAmount,
        uint256 nativeValue,
        address feeToken,
        uint256 feeAmount
    ) internal {
        uint256 balanceBefore = _setApprovals(
            bridgeContract, bridgeToken, bridgeAmount, feeToken, feeAmount
        );
        bool isNativeBridge = bridgeToken == address(0);
        uint256 callValue =
            isNativeBridge ? nativeValue + bridgeAmount : nativeValue;

        // Never let a bridge call dip into ETH that is reserved for failed
        // prior refunds.
        if (address(this).balance < callValue + reservedRefundEth) {
            revert WouldConsumeReservedRefund();
        }

        (bool success, bytes memory result) =
            bridgeContract.call{ value: callValue }(patchedCalldata);
        if (!success) revert BridgeFailed(result);

        uint256 balanceAfter = isNativeBridge
            ? address(this).balance
            : IERC20(bridgeToken).balanceOf(address(this));
        // For native bridges, the call also forwards `nativeValue` as the
        // relay fee. Require the bridge to consume the full `bridgeAmount
        // + nativeValue` so an unconsumed relay-fee remainder cannot mask
        // under-consumption of the principal. Bridges that refund any
        // portion of `nativeValue` will revert here and must be invoked
        // with an exact `nativeValue` quote.
        uint256 minConsumed =
            isNativeBridge ? bridgeAmount + nativeValue : bridgeAmount;
        if (balanceBefore - balanceAfter < minConsumed) {
            revert BridgeDidNotConsumeTokens();
        }

        _resetApprovals(bridgeContract, bridgeToken, feeToken);
    }

    /// @dev `_requireFeeTokenNotBridgeToken` already rejects
    /// `feeToken == bridgeToken`, so the bridge-token approval here
    /// covers only `bridgeAmount` and the fee-token approval is always
    /// a separate ERC20.
    function _setApprovals(
        address bridgeContract,
        address bridgeToken,
        uint256 bridgeAmount,
        address feeToken,
        uint256 feeAmount
    ) internal returns (uint256 balanceBefore) {
        if (bridgeToken == address(0)) {
            balanceBefore = address(this).balance;
        } else {
            balanceBefore = IERC20(bridgeToken).balanceOf(address(this));
            SafeTransferLib.safeApprove(bridgeToken, bridgeContract, 0);
            SafeTransferLib.safeApprove(
                bridgeToken, bridgeContract, bridgeAmount
            );
        }

        if (feeToken != address(0) && feeAmount > 0) {
            SafeTransferLib.safeApprove(feeToken, bridgeContract, 0);
            SafeTransferLib.safeApprove(feeToken, bridgeContract, feeAmount);
        }
    }

    function _resetApprovals(
        address bridgeContract,
        address bridgeToken,
        address feeToken
    ) internal {
        if (bridgeToken != address(0)) {
            SafeTransferLib.safeApprove(bridgeToken, bridgeContract, 0);
        }
        if (feeToken != address(0)) {
            SafeTransferLib.safeApprove(feeToken, bridgeContract, 0);
        }
    }

    function _patchUint256(
        bytes memory data,
        uint256 offset,
        uint256 value
    ) internal pure {
        assembly {
            mstore(add(add(data, 32), offset), value)
        }
    }

    function _selector(
        bytes memory data
    ) internal pure returns (bytes4 selector_) {
        assembly {
            selector_ := mload(add(data, 32))
        }
    }

    function _transferAvailable(
        address token,
        address to,
        uint256 amount
    ) internal returns (uint256 sent) {
        uint256 available = _tokenBalance(token, address(this));
        sent = available < amount ? available : amount;
        if (sent > 0) {
            SafeTransferLib.safeTransfer(token, to, sent);
        }
    }

    function _tokenBalance(
        address token,
        address account
    ) internal view returns (uint256) {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _preCallTokenBalance(
        address token,
        uint256 deliveredAmount
    ) internal view returns (uint256) {
        if (token == address(0)) return 0;
        uint256 balance = IERC20(token).balanceOf(address(this));
        return balance > deliveredAmount ? balance - deliveredAmount : 0;
    }

    function _refundExcessEth(
        address recipient,
        uint256 baseBalance
    ) internal {
        uint256 currentBalance = address(this).balance;
        if (currentBalance <= baseBalance) return;

        uint256 amount = currentBalance - baseBalance;
        (bool success,) = recipient.call{ value: amount }("");
        if (!success) {
            // Track the failed refund so it is excluded from spendable hub
            // float. Without this, a later route can consume the stranded ETH
            // as its own hub contribution before `rescueETH` recovers it.
            reservedRefundEth += amount;
            emit RefundFailed(recipient, amount);
        }
    }

    /// @dev Refund any feeToken delivered for this call but not consumed
    /// by the bridge. `baseBalance` is `balanceOf(this) - feeAmount` taken
    /// at entry to `executeRoute`, so `currentBalance - baseBalance` is
    /// exactly the unspent feeToken delivered for this route.
    function _refundExcessFeeToken(
        address feeToken,
        address recipient,
        uint256 baseBalance
    ) internal {
        _refundTokenSurplus(feeToken, recipient, baseBalance);
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

    receive() external payable { }
}
