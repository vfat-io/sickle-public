// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice FlowState C1 Market interface used by the direct exact-quote lane.
/// @dev Selectors and argument order are pinned against Robinhood Market
/// implementation 0xdffa98637403e3872e21ac12b72d9015acbcb03f.
interface IFlowStateMarket {
    function poolByToken(
        address inventoryToken
    ) external view returns (address pool);

    /// @dev Directional lookup: `(inventoryToken, quoteAsset)` resolves the C1
    /// pool; the reversed pair resolves zero on the reviewed deployment.
    function poolByPair(
        address inventoryToken,
        address quoteAsset
    ) external view returns (address pool);

    function quoteBuyFromPool(
        address pool,
        address quoteAsset,
        uint256 tokenAmount
    )
        external
        view
        returns (
            bool available,
            uint256 fillableAmount,
            uint256 quoteAmount,
            uint256 feeAmount,
            uint16 feeBps,
            address resolvedQuoteAsset
        );

    function buyFromPool(
        address pool,
        address quoteAsset,
        uint256 tokenAmount,
        string calldata reseller,
        address recipient
    ) external returns (uint256 amountOut, uint256 quoteAmountUsed);

    function buyFromPoolExactQuote(
        address pool,
        address quoteAsset,
        uint256 quoteAmount,
        string calldata reseller,
        address recipient
    ) external returns (uint256 amountOut, uint256 quoteAmountUsed);

    /// @notice Spend up to `quoteAmount` while enforcing a minimum inventory
    /// output and execution deadline. Capacity-limited fills may use less than
    /// `quoteAmount`; callers must settle the unused quote asset themselves.
    function buyFromPoolExactQuoteBounded(
        address pool,
        address quoteAsset,
        uint256 quoteAmount,
        string calldata reseller,
        address recipient,
        uint256 minAmountOut,
        uint256 deadline
    ) external returns (uint256 amountOut, uint256 quoteAmountUsed);
}
