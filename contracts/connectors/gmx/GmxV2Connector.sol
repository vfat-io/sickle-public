// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import {
    IGmxExchangeRouter,
    GmxBaseOrderUtils,
    GmxOrder
} from "contracts/interfaces/external/gmx/IGmxV2.sol";
import { Sickle } from "contracts/Sickle.sol";

// Connector that opens / closes a perp position on GMX V2 (Synthetics).
//
// Stateless: every entry point is delegate-called by Sickle.multicall, so
// `address(this)` is the Sickle. The connector never holds funds.
//
// Order flow (for both increase and decrease):
//   1. Sickle approves the GMX plugin Router for the collateral token.
//   2. Sickle bundles three calls via ExchangeRouter.multicall:
//        a. sendWnt(orderVault, executionFee)        — keeper gas budget
//        b. sendTokens(collateral, orderVault, amt)  — only on increase
//        c. createOrder(params)                       — records the order
//   3. The GMX keeper executes the order in a later block. For increase,
//      a position is opened/grown; for decrease, collateral + PnL flows
//      to `params.addresses.receiver` (we set this to the Sickle owner).
//
// Cancellation refunds go to `cancellationReceiver` (Sickle owner).
//
// Per-order callback contract is set by the strategy; passing address(0)
// disables it.
contract GmxV2Connector {
    address public immutable exchangeRouter;
    address public immutable router;
    address public immutable orderVault;

    // Order action selectors used as fee tags by Sickle's FeesLib if the
    // strategy chooses to charge — kept here so the connector can be
    // composed with FeesLib.chargeFees(...) at the strategy layer.
    bytes4 public constant OPEN_SHORT_FEE = bytes4(keccak256("openShort"));
    bytes4 public constant CLOSE_SHORT_FEE = bytes4(keccak256("closeShort"));

    struct OpenShortParams {
        address market;
        address collateralToken;
        uint256 collateralAmount;
        uint256 sizeDeltaUsd;
        uint256 acceptablePrice;
        uint256 executionFee;
        address callbackContract;
        uint256 callbackGasLimit;
        bytes32 referralCode;
    }

    struct CloseShortParams {
        address market;
        address collateralToken;
        uint256 collateralDeltaAmount;
        uint256 sizeDeltaUsd;
        uint256 acceptablePrice;
        uint256 executionFee;
        address receiver;
        address callbackContract;
        uint256 callbackGasLimit;
        bytes32 referralCode;
    }

    constructor(
        address exchangeRouter_,
        address router_,
        address orderVault_
    ) {
        exchangeRouter = exchangeRouter_;
        router = router_;
        orderVault = orderVault_;
    }

    /// @notice Submit a market-increase short order against `market`.
    /// @dev Runs in the Sickle's context via delegatecall. Sickle must hold
    ///      `collateralAmount` of `collateralToken` and `executionFee` of
    ///      native ETH at call time. Pulls collateral via the GMX plugin
    ///      Router (one-time approval scoped to the order).
    function openShort(
        OpenShortParams calldata p
    ) external payable returns (bytes32 key) {
        bool hasCollateral = p.collateralAmount > 0;
        address sickleOwner = _sickleOwner();
        if (hasCollateral) {
            SafeTransferLib.safeApprove(
                p.collateralToken, router, p.collateralAmount
            );
        }

        GmxBaseOrderUtils.CreateOrderParams memory params = GmxBaseOrderUtils
            .CreateOrderParams({
            addresses: GmxBaseOrderUtils.CreateOrderParamsAddresses({
                receiver: sickleOwner,
                cancellationReceiver: sickleOwner,
                callbackContract: p.callbackContract,
                uiFeeReceiver: address(0),
                market: p.market,
                initialCollateralToken: p.collateralToken,
                swapPath: new address[](0)
            }),
            numbers: GmxBaseOrderUtils.CreateOrderParamsNumbers({
                sizeDeltaUsd: p.sizeDeltaUsd,
                initialCollateralDeltaAmount: 0,
                triggerPrice: 0,
                acceptablePrice: p.acceptablePrice,
                executionFee: p.executionFee,
                callbackGasLimit: p.callbackGasLimit,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: GmxOrder.OrderType.MarketIncrease,
            decreasePositionSwapType: GmxOrder.DecreasePositionSwapType.NoSwap,
            isLong: false,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: p.referralCode,
            dataList: new bytes32[](0)
        });

        // sendTokens is skipped when collateralAmount == 0 (size-only
        // increase, e.g. growShort during a delta rebalance). GMX's
        // pluginTransfer would revert on a 0-amount call for some tokens.
        bytes[] memory calls = new bytes[](hasCollateral ? 3 : 2);
        calls[0] = abi.encodeCall(
            IGmxExchangeRouter.sendWnt, (orderVault, p.executionFee)
        );
        if (hasCollateral) {
            calls[1] = abi.encodeCall(
                IGmxExchangeRouter.sendTokens,
                (p.collateralToken, orderVault, p.collateralAmount)
            );
            calls[2] =
                abi.encodeCall(IGmxExchangeRouter.createOrder, (params));
        } else {
            calls[1] =
                abi.encodeCall(IGmxExchangeRouter.createOrder, (params));
        }

        bytes[] memory results = IGmxExchangeRouter(exchangeRouter).multicall{
            value: p.executionFee
        }(calls);
        key = abi.decode(results[results.length - 1], (bytes32));

        if (hasCollateral) {
            SafeTransferLib.safeApprove(p.collateralToken, router, 0);
        }
    }

    /// @notice Submit a market-decrease short order to close (or shrink) an
    ///         existing short on `market`.
    /// @dev `collateralDeltaAmount` is the collateral the user wants pulled
    ///      out; pass 0 to leave collateral in place and only realize PnL on
    ///      the size reduction. `receiver` gets collateral + PnL when the
    ///      keeper executes.
    function closeShort(
        CloseShortParams calldata p
    ) external payable returns (bytes32 key) {
        address sickleOwner = _sickleOwner();
        GmxBaseOrderUtils.CreateOrderParams memory params = GmxBaseOrderUtils
            .CreateOrderParams({
            addresses: GmxBaseOrderUtils.CreateOrderParamsAddresses({
                receiver: p.receiver,
                cancellationReceiver: sickleOwner,
                callbackContract: p.callbackContract,
                uiFeeReceiver: address(0),
                market: p.market,
                initialCollateralToken: p.collateralToken,
                swapPath: new address[](0)
            }),
            numbers: GmxBaseOrderUtils.CreateOrderParamsNumbers({
                sizeDeltaUsd: p.sizeDeltaUsd,
                initialCollateralDeltaAmount: p.collateralDeltaAmount,
                triggerPrice: 0,
                acceptablePrice: p.acceptablePrice,
                executionFee: p.executionFee,
                callbackGasLimit: p.callbackGasLimit,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: GmxOrder.OrderType.MarketDecrease,
            decreasePositionSwapType: GmxOrder
                .DecreasePositionSwapType
                .SwapPnlTokenToCollateralToken,
            isLong: false,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: p.referralCode,
            dataList: new bytes32[](0)
        });

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            IGmxExchangeRouter.sendWnt, (orderVault, p.executionFee)
        );
        calls[1] = abi.encodeCall(IGmxExchangeRouter.createOrder, (params));

        bytes[] memory results = IGmxExchangeRouter(exchangeRouter).multicall{
            value: p.executionFee
        }(calls);
        key = abi.decode(results[1], (bytes32));
    }

    /// @notice Claim accrued GMX V2 funding fees on `markets` for `tokens`
    ///         into the Sickle (delegate-call context: `address(this)` is the
    ///         Sickle). The strategy is responsible for charging fees and
    ///         flushing the remainder to the user, or redeploying it as
    ///         collateral in the same multicall (compound flow).
    function claimFunding(
        address[] calldata markets,
        address[] calldata tokens
    ) external payable returns (uint256[] memory amounts) {
        amounts = IGmxExchangeRouter(exchangeRouter).claimFundingFees(
            markets, tokens, address(this)
        );
    }

    /// @notice Cancel a pending GMX V2 order owned by this Sickle. The
    ///         ExchangeRouter checks `msg.sender == order.account`, so this
    ///         only works for orders the Sickle itself created. Returns the
    ///         locked execution fee (and increase-order collateral) from
    ///         OrderVault to the order's `cancellationReceiver` (set to the
    ///         Sickle owner at order creation).
    function cancelOrder(
        bytes32 key
    ) external payable {
        IGmxExchangeRouter(exchangeRouter).cancelOrder(key);
    }

    function _sickleOwner() private view returns (address) {
        return Sickle(payable(address(this))).owner();
    }
}
