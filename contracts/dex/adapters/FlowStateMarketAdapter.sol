// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IFlowStateMarket
} from "contracts/interfaces/external/flowstate/IFlowStateMarket.sol";

/// @title FlowStateMarketAdapter
/// @notice Direct one-way execution for FlowState C1 inventory pools. The
/// requested ERC20 quote input is an upper bound: the selected allow-listed
/// Market may
/// consume less on a capacity-limited fill, and the adapter immediately sends
/// only that step's unused quote asset to the encoded residual recipient. The
/// inventory token is delivered directly to SwapRouter. This adapter never
/// takes custody.
/// @dev `dexData = abi.encode(physicalPool, marketMinAmountOut, marketDeadline,
/// residualRecipient, marketMaxQuoteAmount)`. `marketMinAmountOut` is the gross
/// inventory output before SwapRouter's final fee. `marketMaxQuoteAmount` caps
/// the amount approved and submitted to the Market independently of the outer
/// exact-input upper bound. Reverse inventory sales are not supported: the
/// reviewed Market quote model covers only quote-asset -> inventory-token buys.
contract FlowStateMarketAdapter is DexAdapterBase {
    struct FlowStateDexData {
        address physicalPool;
        uint256 marketMinAmountOut;
        uint256 marketDeadline;
        address residualRecipient;
        uint256 marketMaxQuoteAmount;
    }

    struct FillState {
        uint256 inputBalanceBefore;
        uint256 preExistingInputBalance;
        uint256 outputBalanceBefore;
        uint256 reportedAmountOut;
        uint256 reportedQuoteAmountUsed;
        uint256 inputBalanceAfter;
        uint256 outputBalanceAfter;
    }

    error InvalidDexType();
    error InvalidDexData();
    error InvalidMarket();
    error InvalidPoolDirection();
    error InvalidInputBalance();
    error InputBalanceConsumed();
    error OutputBalanceConsumed();
    error MarketDeadlineExpired();
    error InvalidMarketReturnData();
    error QuoteAmountUsedMismatch(uint256 reported, uint256 realized);
    error QuoteAmountUsedExceedsMaximum(uint256 realized, uint256 maximum);
    error AmountOutMismatch(uint256 reported, uint256 realized);
    error InsufficientMarketOutput(uint256 realized, uint256 minimum);

    /// @notice Requested versus realized FlowState volume for one bounded
    /// fill. `realizedQuoteAmount` and `realizedInventoryAmount` have already
    /// been reconciled against SwapRouter's token balance deltas.
    event FlowStateMarketFill(
        address indexed physicalPool,
        address indexed quoteAsset,
        address indexed inventoryToken,
        address residualRecipient,
        uint256 requestedQuoteAmount,
        uint256 realizedQuoteAmount,
        uint256 refundedQuoteAmount,
        uint256 realizedInventoryAmount,
        uint256 marketMinAmountOut,
        uint256 marketDeadline
    );

    /// @dev The fourth constructor argument is retained for deployment-helper
    /// compatibility. V4 deliberately does not bind a Market at deployment:
    /// each route supplies its reviewed, RouterAllowlist-approved Market in
    /// `step.router`.
    constructor(
        address admin_,
        address allowlist_,
        address
    ) DexAdapterBase(admin_, allowlist_) { }

    function version() external pure override returns (uint16) {
        return 4;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256) {
        if (step.dexType != uint8(DexType.FlowStateMarket)) {
            revert InvalidDexType();
        }
        if (
            step.dexData.length != 160 || amountIn == 0
                || step.tokenIn == address(0) || step.tokenOut == address(0)
                || step.tokenIn == step.tokenOut
        ) revert InvalidDexData();
        FlowStateDexData memory data =
            abi.decode(step.dexData, (FlowStateDexData));
        if (
            data.physicalPool == address(0) || data.marketMinAmountOut == 0
                || data.marketDeadline == 0
                || data.residualRecipient == address(0)
                || data.marketMaxQuoteAmount == 0
                || data.marketMaxQuoteAmount > amountIn
        ) revert InvalidDexData();
        if (block.timestamp > data.marketDeadline) {
            revert MarketDeadlineExpired();
        }

        // Defence in depth: SwapRouter checks this before dispatch, while the
        // adapter independently binds its approval/call to this exact
        // allow-listed Market. A Market must also implement the reviewed
        // directional lookup ABI with canonical single-address return words.
        address market = step.router;
        allowlist.requireAllowed(market);
        if (
            _marketPoolByToken(market, step.tokenOut) != data.physicalPool
                || _marketPoolByPair(market, step.tokenOut, step.tokenIn)
                    != data.physicalPool
        ) revert InvalidPoolDirection();

        (uint256 realizedQuoteAmount, uint256 realizedAmountOut) =
            _executeBoundedFill(step, amountIn, data, market);
        uint256 refundAmount = amountIn - realizedQuoteAmount;
        if (refundAmount > 0) {
            _adapterPullTo(step.tokenIn, refundAmount, data.residualRecipient);
        }

        emit FlowStateMarketFill(
            data.physicalPool,
            step.tokenIn,
            step.tokenOut,
            data.residualRecipient,
            amountIn,
            realizedQuoteAmount,
            refundAmount,
            realizedAmountOut,
            data.marketMinAmountOut,
            data.marketDeadline
        );

        // Informational only; SwapRouter independently measures the same
        // tokenOut balance delta as its authoritative hop output.
        return realizedAmountOut;
    }

    function _executeBoundedFill(
        SwapStep calldata step,
        uint256 amountIn,
        FlowStateDexData memory data,
        address market
    )
        internal
        returns (uint256 realizedQuoteAmount, uint256 realizedAmountOut)
    {
        // Separate this step's requested upper bound from balances belonging
        // to other callers/routes. This lets a short fill refund exactly its
        // own unused input without exposing pre-existing SwapRouter custody.
        FillState memory state;
        state.inputBalanceBefore = IERC20(step.tokenIn).balanceOf(msg.sender);
        if (state.inputBalanceBefore < amountIn) revert InvalidInputBalance();
        state.preExistingInputBalance = state.inputBalanceBefore - amountIn;
        state.outputBalanceBefore = IERC20(step.tokenOut).balanceOf(msg.sender);

        _adapterApprove(step.tokenIn, market, data.marketMaxQuoteAmount);
        bytes memory result = _adapterCall(
            market,
            0,
            abi.encodeCall(
                IFlowStateMarket.buyFromPoolExactQuoteBounded,
                (
                    data.physicalPool,
                    step.tokenIn,
                    data.marketMaxQuoteAmount,
                    "vfat",
                    msg.sender,
                    data.marketMinAmountOut,
                    data.marketDeadline
                )
            )
        );
        _adapterApprove(step.tokenIn, market, 0);

        if (result.length != 64) revert InvalidMarketReturnData();
        (state.reportedAmountOut, state.reportedQuoteAmountUsed) =
            abi.decode(result, (uint256, uint256));

        state.inputBalanceAfter = IERC20(step.tokenIn).balanceOf(msg.sender);
        if (state.inputBalanceAfter < state.preExistingInputBalance) {
            revert InputBalanceConsumed();
        }
        if (state.inputBalanceAfter > state.inputBalanceBefore) {
            revert InvalidInputBalance();
        }
        realizedQuoteAmount = state.inputBalanceBefore - state.inputBalanceAfter;
        if (state.reportedQuoteAmountUsed != realizedQuoteAmount) {
            revert QuoteAmountUsedMismatch(
                state.reportedQuoteAmountUsed, realizedQuoteAmount
            );
        }
        if (realizedQuoteAmount > data.marketMaxQuoteAmount) {
            revert QuoteAmountUsedExceedsMaximum(
                realizedQuoteAmount, data.marketMaxQuoteAmount
            );
        }

        state.outputBalanceAfter = IERC20(step.tokenOut).balanceOf(msg.sender);
        if (state.outputBalanceAfter < state.outputBalanceBefore) {
            revert OutputBalanceConsumed();
        }
        realizedAmountOut = state.outputBalanceAfter - state.outputBalanceBefore;
        if (state.reportedAmountOut != realizedAmountOut) {
            revert AmountOutMismatch(state.reportedAmountOut, realizedAmountOut);
        }
        if (realizedAmountOut < data.marketMinAmountOut) {
            revert InsufficientMarketOutput(
                realizedAmountOut, data.marketMinAmountOut
            );
        }
    }

    /// @dev A high-level external call accepts ABI return data longer than one
    /// word. Keep this validation exact so a different allow-listed router
    /// cannot masquerade as a FlowState Market through a loose decoder.
    function _marketPoolByToken(
        address market,
        address inventoryToken
    ) internal view returns (address) {
        (bool success, bytes memory result) = market.staticcall(
            abi.encodeCall(IFlowStateMarket.poolByToken, (inventoryToken))
        );
        return _decodeMarketAddress(success, result);
    }

    function _marketPoolByPair(
        address market,
        address inventoryToken,
        address quoteAsset
    ) internal view returns (address) {
        (bool success, bytes memory result) = market.staticcall(
            abi.encodeCall(
                IFlowStateMarket.poolByPair, (inventoryToken, quoteAsset)
            )
        );
        return _decodeMarketAddress(success, result);
    }

    function _decodeMarketAddress(
        bool success,
        bytes memory result
    ) internal pure returns (address marketAddress) {
        if (!success || result.length != 32) revert InvalidMarket();
        uint256 resultWord;
        assembly {
            resultWord := mload(add(result, 0x20))
        }
        if (resultWord >> 160 != 0) revert InvalidMarket();
        marketAddress = address(uint160(resultWord));
    }
}
