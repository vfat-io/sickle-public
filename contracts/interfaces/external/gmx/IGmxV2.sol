// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Subset of GMX V2 (Synthetics) interfaces needed by Sickle's basis-carry
// strategy. Mirrors the canonical types in gmx-io/gmx-synthetics; only the
// fields we read or write are declared.

library GmxOrder {
    enum OrderType {
        MarketSwap,
        LimitSwap,
        MarketIncrease,
        LimitIncrease,
        MarketDecrease,
        LimitDecrease,
        StopLossDecrease,
        Liquidation,
        StopIncrease
    }

    enum DecreasePositionSwapType {
        NoSwap,
        SwapPnlTokenToCollateralToken,
        SwapCollateralTokenToPnlToken
    }
}

library GmxBaseOrderUtils {
    struct CreateOrderParams {
        CreateOrderParamsAddresses addresses;
        CreateOrderParamsNumbers numbers;
        GmxOrder.OrderType orderType;
        GmxOrder.DecreasePositionSwapType decreasePositionSwapType;
        bool isLong;
        bool shouldUnwrapNativeToken;
        bool autoCancel;
        bytes32 referralCode;
        bytes32[] dataList;
    }

    struct CreateOrderParamsAddresses {
        address receiver;
        address cancellationReceiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address initialCollateralToken;
        address[] swapPath;
    }

    struct CreateOrderParamsNumbers {
        uint256 sizeDeltaUsd;
        uint256 initialCollateralDeltaAmount;
        uint256 triggerPrice;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 callbackGasLimit;
        uint256 minOutputAmount;
        uint256 validFromTime;
    }
}

// Minimal IExchangeRouter — only the calls we need.
interface IGmxExchangeRouter {
    function sendWnt(
        address receiver,
        uint256 amount
    ) external payable;

    function sendTokens(
        address token,
        address receiver,
        uint256 amount
    ) external payable;

    function createOrder(
        GmxBaseOrderUtils.CreateOrderParams calldata params
    ) external payable returns (bytes32);

    function cancelOrder(
        bytes32 key
    ) external payable;

    function claimFundingFees(
        address[] calldata markets,
        address[] calldata tokens,
        address receiver
    ) external payable returns (uint256[] memory);

    function multicall(
        bytes[] calldata data
    ) external payable returns (bytes[] memory results);
}

// Plugin router that the Sickle approves for collateral pulls.
// `pluginTransfer` is restricted to whitelisted plugins (ExchangeRouter etc.).
interface IGmxRouter { }

interface IGmxDataStore {
    function getUint(
        bytes32 key
    ) external view returns (uint256);
    function getInt(
        bytes32 key
    ) external view returns (int256);
    function getAddress(
        bytes32 key
    ) external view returns (address);
}

// Mirrors PositionStoreUtils + Keys derivation for the per-field reads we
// need without ABI-decoding the full Position.Props struct. Each field is
// stored in DataStore at keccak256(abi.encode(positionKey, FIELD_CONSTANT)).
// This decouples the registry from Position.Props evolution.
library GmxStorageKeys {
    function _str(
        string memory s
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(s));
    }

    function positionKey(
        address account,
        address market,
        address collateralToken,
        bool isLong
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, market, collateralToken, isLong));
    }

    function sizeInUsdKey(
        bytes32 posKey
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(posKey, _str("SIZE_IN_USD")));
    }

    function sizeInTokensKey(
        bytes32 posKey
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(posKey, _str("SIZE_IN_TOKENS")));
    }

    function collateralAmountKey(
        bytes32 posKey
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(posKey, _str("COLLATERAL_AMOUNT")));
    }

    function claimableFundingAmountKey(
        address market,
        address token,
        address account
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(_str("CLAIMABLE_FUNDING_AMOUNT"), market, token, account)
        );
    }

    function marketTokenKey(
        address market
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(market, _str("MARKET_TOKEN")));
    }

    function marketLongTokenKey(
        address market
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(market, _str("LONG_TOKEN")));
    }

    function marketShortTokenKey(
        address market
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(market, _str("SHORT_TOKEN")));
    }

    /// Per-market saved funding factor (1e30 fixed-point per second). Sign
    /// encodes direction: positive ⇔ longs pay shorts, negative ⇔ shorts
    /// pay longs. The registry uses this as an inexpensive approximation for
    /// automation triggers; GMX Reader's next-rate path also applies stable
    /// funding bands and caps.
    function savedFundingFactorPerSecondKey(
        address market
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(_str("SAVED_FUNDING_FACTOR_PER_SECOND"), market)
        );
    }

    /// Open interest of (market, collateralToken, isLong), in 1e30 USD.
    /// The total per-side OI sums across both possible collateral tokens
    /// (long-token-collateralized and short-token-collateralized).
    function openInterestKey(
        address market,
        address collateralToken,
        bool isLong
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(_str("OPEN_INTEREST"), market, collateralToken, isLong)
        );
    }
}

library GmxEvent {
    // Mirrors EventUtils.EventLogData. Used as the callback payload type.
    struct AddressKeyValue {
        string key;
        address value;
    }

    struct AddressArrayKeyValue {
        string key;
        address[] value;
    }

    struct AddressItems {
        AddressKeyValue[] items;
        AddressArrayKeyValue[] arrayItems;
    }

    struct UintKeyValue {
        string key;
        uint256 value;
    }

    struct UintArrayKeyValue {
        string key;
        uint256[] value;
    }

    struct UintItems {
        UintKeyValue[] items;
        UintArrayKeyValue[] arrayItems;
    }

    struct IntKeyValue {
        string key;
        int256 value;
    }

    struct IntArrayKeyValue {
        string key;
        int256[] value;
    }

    struct IntItems {
        IntKeyValue[] items;
        IntArrayKeyValue[] arrayItems;
    }

    struct BoolKeyValue {
        string key;
        bool value;
    }

    struct BoolArrayKeyValue {
        string key;
        bool[] value;
    }

    struct BoolItems {
        BoolKeyValue[] items;
        BoolArrayKeyValue[] arrayItems;
    }

    struct Bytes32KeyValue {
        string key;
        bytes32 value;
    }

    struct Bytes32ArrayKeyValue {
        string key;
        bytes32[] value;
    }

    struct Bytes32Items {
        Bytes32KeyValue[] items;
        Bytes32ArrayKeyValue[] arrayItems;
    }

    struct BytesKeyValue {
        string key;
        bytes value;
    }

    struct BytesArrayKeyValue {
        string key;
        bytes[] value;
    }

    struct BytesItems {
        BytesKeyValue[] items;
        BytesArrayKeyValue[] arrayItems;
    }

    struct StringKeyValue {
        string key;
        string value;
    }

    struct StringArrayKeyValue {
        string key;
        string[] value;
    }

    struct StringItems {
        StringKeyValue[] items;
        StringArrayKeyValue[] arrayItems;
    }

    struct EventLogData {
        AddressItems addressItems;
        UintItems uintItems;
        IntItems intItems;
        BoolItems boolItems;
        Bytes32Items bytes32Items;
        BytesItems bytesItems;
        StringItems stringItems;
    }
}

interface IGmxOrderCallbackReceiver {
    function afterOrderExecution(
        bytes32 key,
        GmxEvent.EventLogData calldata orderData,
        GmxEvent.EventLogData calldata eventData
    ) external;

    function afterOrderCancellation(
        bytes32 key,
        GmxEvent.EventLogData calldata orderData,
        GmxEvent.EventLogData calldata eventData
    ) external;

    function afterOrderFrozen(
        bytes32 key,
        GmxEvent.EventLogData calldata orderData,
        GmxEvent.EventLogData calldata eventData
    ) external;
}
