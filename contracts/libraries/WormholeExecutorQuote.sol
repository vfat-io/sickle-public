// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title WormholeExecutorQuote
/// @notice Client-side verification of a Wormhole Executor EQ01 signed
/// quote. The on-chain Executor contract intentionally does NOT verify
/// the quote signature, so a compromised relay-provider endpoint could
/// otherwise return a well-formed but invalid quote and the full
/// executorFee would still be paid out of `Executor.requestExecution`.
/// Callers verify client-side before broadcasting.
/// @dev Canonical wire format (see README in
/// github.com/wormholelabs-xyz/example-messaging-executor):
///   Header (68 bytes):
///     prefix(4) | quoterAddress(20) | payeeAddress(32)
///     | srcChain(2) | dstChain(2) | expiryTime(8)
///   Pricing (32 bytes):
///     baseFee(8) | dstGasPrice(8) | srcPrice(8) | dstPrice(8)
///   Signature (65 bytes):
///     r(32) | s(32) | v(1)  — Quoter's signature over the preceding
///     100 bytes.
/// Total: 165 bytes.
library WormholeExecutorQuote {
    uint256 internal constant BODY_LEN = 100;
    uint256 internal constant TOTAL_LEN = 165;
    bytes4 internal constant PREFIX = "EQ01";

    error QuoteWrongLength(uint256 provided, uint256 expected);
    error QuoteWrongPrefix(bytes4 found, bytes4 expected);
    /// @notice Header-encoded `quoterAddress` is the zero address.
    /// @dev Must be rejected up front: `ecrecover` returns
    /// `address(0)` on malformed signatures, so accepting a zero
    /// quoter would make any junk signature verify trivially.
    error QuoteZeroQuoter();
    error QuoteSrcChainMismatch(uint16 found, uint16 expected);
    error QuoteDstChainMismatch(uint16 found, uint16 expected);
    error QuoteExpired(uint64 expiry, uint256 nowTs);
    error QuotePayeeNotEvmAddress(bytes32 payee);
    error QuoteSignatureInvalid();
    error QuoteQuoterMismatch(address found, address expected);
    error QuotePayeeMismatch(address found, address expected);
    /// @notice Server-returned `estimatedCost` is not what the signed
    /// pricing fields + relayInstructions would deterministically
    /// produce. Binds the wire `executorFee` back to the signature.
    error QuoteFeeMismatch(uint256 provided, uint256 expected);
    /// @notice `relayInstructions` contained more than one drop-off
    /// (matches the upstream ExecutorQuoter behavior).
    error QuoteMoreThanOneDropOff();
    /// @notice `relayInstructions` used an unknown type byte.
    error QuoteUnsupportedInstruction(uint8 ixType);
    /// @notice A recognized `relayInstructions` entry ended before its
    /// fixed-width body was fully encoded.
    error QuoteInstructionTruncated(
        uint8 ixType, uint256 offset, uint256 required, uint256 available
    );

    struct Header {
        address quoter;
        address payee;
        uint16 srcChain;
        uint16 dstChain;
        uint64 expiry;
    }

    /// @dev Pricing fields committed to by the quoter's signature
    /// (bytes 68..100 of the signed EQ01 body).
    struct Pricing {
        uint64 baseFee;
        uint64 dstGasPrice;
        uint64 srcPrice;
        uint64 dstPrice;
    }

    /// @dev Chain-specific decimal constants used by
    /// `ExecutorQuoter.estimateQuote`. These are operator-supplied
    /// rather than read from the signed quote because the quote does
    /// not carry them, and the on-chain Quoter contract stores them
    /// in `chainInfos[dstChain]` / the `SRC_TOKEN_DECIMALS` immutable.
    /// For EVM-EVM rehearsals the typical values are 18/9/18.
    struct ChainParams {
        uint8 srcTokenDecimals;
        uint8 dstGasPriceDecimals;
        uint8 dstNativeDecimals;
    }

    uint8 private constant QUOTE_DECIMALS = 10;
    uint8 private constant DECIMAL_RESOLUTION = 18;
    uint8 private constant RELAY_IX_GAS = 1;
    uint8 private constant RELAY_IX_DROP_OFF = 2;

    /// @notice Decode + verify an EQ01 signed quote.
    /// @dev Reverts on any failure. Returns the decoded header on
    /// success. When `expectedQuoter` or `expectedPayee` is
    /// `address(0)` the corresponding pin is skipped (useful for
    /// testnet rehearsals where the legit provider address is not yet
    /// baked into operator tooling).
    function verify(
        bytes memory signedQuote,
        uint16 expectedSrc,
        uint16 expectedDst,
        address expectedQuoter,
        address expectedPayee
    ) internal view returns (Header memory h) {
        if (signedQuote.length != TOTAL_LEN) {
            revert QuoteWrongLength(signedQuote.length, TOTAL_LEN);
        }

        bytes4 prefix;
        address quoter;
        bytes32 payee;
        uint16 srcChain;
        uint16 dstChain;
        uint64 expiry;
        assembly {
            let p := add(signedQuote, 32)
            prefix := mload(p)
            quoter := shr(96, mload(add(p, 4)))
            payee := mload(add(p, 24))
            srcChain := shr(240, mload(add(p, 56)))
            dstChain := shr(240, mload(add(p, 58)))
            expiry := shr(192, mload(add(p, 60)))
        }

        if (prefix != PREFIX) revert QuoteWrongPrefix(prefix, PREFIX);
        // Fail closed on zero quoter. ecrecover returns address(0) on
        // malformed sigs, so a header with quoter=0 would otherwise
        // accept any junk signature. Must come before the sig check.
        if (quoter == address(0)) revert QuoteZeroQuoter();
        if (srcChain != expectedSrc) {
            revert QuoteSrcChainMismatch(srcChain, expectedSrc);
        }
        if (dstChain != expectedDst) {
            revert QuoteDstChainMismatch(dstChain, expectedDst);
        }
        if (expiry <= block.timestamp) {
            revert QuoteExpired(expiry, block.timestamp);
        }
        if (uint256(payee) >> 160 != 0) {
            revert QuotePayeeNotEvmAddress(payee);
        }

        _verifySignature(signedQuote, quoter);

        if (
            expectedQuoter != address(0) && quoter != expectedQuoter
        ) {
            revert QuoteQuoterMismatch(quoter, expectedQuoter);
        }
        address payeeAddr = address(uint160(uint256(payee)));
        if (expectedPayee != address(0) && payeeAddr != expectedPayee) {
            revert QuotePayeeMismatch(payeeAddr, expectedPayee);
        }

        return Header({
            quoter: quoter,
            payee: payeeAddr,
            srcChain: srcChain,
            dstChain: dstChain,
            expiry: expiry
        });
    }

    /// @notice Bind the HTTP `estimatedCost` to the signed pricing
    /// fields by reproducing `ExecutorQuoter.estimateQuote` in full.
    /// The on-chain `Executor` does not verify payment against the
    /// quote — it just forwards `msg.value` to the payee encoded in
    /// the header — so a compromised relay endpoint can otherwise pair
    /// a legitimate `signedQuote` with an arbitrarily inflated
    /// `estimatedCost` and we overpay.
    /// @dev Reverts with `QuoteFeeMismatch` when the claimed fee is
    /// not exactly what the signed pricing fields + the supplied
    /// `relayInstructions` and chain params produce. Strict equality
    /// is correct because the reference math is pure integer
    /// arithmetic with no hidden rounding or buffer.
    function verifyFee(
        bytes memory signedQuote,
        bytes memory relayInstructions,
        uint256 estimatedCost,
        ChainParams memory chain
    ) internal pure {
        if (signedQuote.length != TOTAL_LEN) {
            revert QuoteWrongLength(signedQuote.length, TOTAL_LEN);
        }
        Pricing memory p = _decodePricing(signedQuote);
        (uint256 gasLimit, uint256 msgValue) =
            _totalGasLimitAndMsgValue(relayInstructions);
        uint256 expected = _estimateQuote(p, chain, gasLimit, msgValue);
        if (estimatedCost != expected) {
            revert QuoteFeeMismatch(estimatedCost, expected);
        }
    }

    /// @dev Extract the 32-byte pricing block that starts at offset
    /// 68 of the signed body.
    function _decodePricing(
        bytes memory signedQuote
    ) private pure returns (Pricing memory p) {
        uint64 baseFee;
        uint64 dstGasPrice;
        uint64 srcPrice;
        uint64 dstPrice;
        assembly {
            let base := add(signedQuote, 32)
            baseFee := shr(192, mload(add(base, 68)))
            dstGasPrice := shr(192, mload(add(base, 76)))
            srcPrice := shr(192, mload(add(base, 84)))
            dstPrice := shr(192, mload(add(base, 92)))
        }
        return Pricing({
            baseFee: baseFee,
            dstGasPrice: dstGasPrice,
            srcPrice: srcPrice,
            dstPrice: dstPrice
        });
    }

    /// @dev Port of `RelayInstructions` encoding + the summation in
    /// `ExecutorQuoter.totalGasLimitAndMsgValue`. Single-pass walk.
    function _totalGasLimitAndMsgValue(
        bytes memory relayInstructions
    ) private pure returns (uint256 gasLimit, uint256 msgValue) {
        uint256 offset;
        uint256 len = relayInstructions.length;
        bool hasDropOff;
        while (offset < len) {
            uint8 ixType = uint8(relayInstructions[offset]);
            offset += 1;
            if (ixType == RELAY_IX_GAS) {
                _requireInstructionBody(ixType, offset, len, 32);
                uint128 ixGasLimit;
                uint128 ixMsgValue;
                assembly {
                    let p := add(add(relayInstructions, 32), offset)
                    ixGasLimit := shr(128, mload(p))
                    ixMsgValue := shr(128, mload(add(p, 16)))
                }
                offset += 32;
                gasLimit += ixGasLimit;
                msgValue += ixMsgValue;
            } else if (ixType == RELAY_IX_DROP_OFF) {
                if (hasDropOff) revert QuoteMoreThanOneDropOff();
                hasDropOff = true;
                _requireInstructionBody(ixType, offset, len, 48);
                uint128 ixMsgValue;
                assembly {
                    let p := add(add(relayInstructions, 32), offset)
                    ixMsgValue := shr(128, mload(p))
                }
                offset += 48;
                msgValue += ixMsgValue;
            } else {
                revert QuoteUnsupportedInstruction(ixType);
            }
        }
    }

    function _requireInstructionBody(
        uint8 ixType,
        uint256 offset,
        uint256 len,
        uint256 required
    ) private pure {
        uint256 available = len - offset;
        if (available < required) {
            revert QuoteInstructionTruncated(
                ixType, offset, required, available
            );
        }
    }

    /// @dev Verbatim port of `ExecutorQuoter.estimateQuote`. Must stay
    /// bit-identical with the upstream reference — any divergence
    /// would silently accept overpayment.
    function _estimateQuote(
        Pricing memory p,
        ChainParams memory chain,
        uint256 gasLimit,
        uint256 msgValue
    ) private pure returns (uint256) {
        uint256 srcChainValueForBaseFee = _normalize(
            p.baseFee, QUOTE_DECIMALS, chain.srcTokenDecimals
        );
        uint256 nSrcPrice =
            _normalize(p.srcPrice, QUOTE_DECIMALS, DECIMAL_RESOLUTION);
        uint256 nDstPrice =
            _normalize(p.dstPrice, QUOTE_DECIMALS, DECIMAL_RESOLUTION);
        uint256 scaledConversion =
            _div(nDstPrice, nSrcPrice, DECIMAL_RESOLUTION);

        uint256 nGasLimitCost = _normalize(
            gasLimit * p.dstGasPrice,
            chain.dstGasPriceDecimals,
            DECIMAL_RESOLUTION
        );
        uint256 srcChainValueForGasLimit = _normalize(
            _mul(nGasLimitCost, scaledConversion, DECIMAL_RESOLUTION),
            DECIMAL_RESOLUTION,
            chain.srcTokenDecimals
        );

        uint256 nMsgValue = _normalize(
            msgValue, chain.dstNativeDecimals, DECIMAL_RESOLUTION
        );
        uint256 srcChainValueForMsgValue = _normalize(
            _mul(nMsgValue, scaledConversion, DECIMAL_RESOLUTION),
            DECIMAL_RESOLUTION,
            chain.srcTokenDecimals
        );

        return srcChainValueForBaseFee + srcChainValueForGasLimit
            + srcChainValueForMsgValue;
    }

    function _normalize(
        uint256 amount,
        uint8 from,
        uint8 to
    ) private pure returns (uint256) {
        if (from > to) return amount / 10 ** uint256(from - to);
        if (from < to) return amount * 10 ** uint256(to - from);
        return amount;
    }

    function _mul(
        uint256 a,
        uint256 b,
        uint8 decimals
    ) private pure returns (uint256) {
        return (a * b) / 10 ** uint256(decimals);
    }

    function _div(
        uint256 a,
        uint256 b,
        uint8 decimals
    ) private pure returns (uint256) {
        return (a * 10 ** uint256(decimals)) / b;
    }

    /// @dev Verify the Quoter's ECDSA signature over the 100-byte
    /// body. The reference spec does not fix the pre-hash convention,
    /// so try raw keccak256(body) first and fall back to the EIP-191
    /// personal-sign prefix. Either passing counts as verified.
    function _verifySignature(
        bytes memory signedQuote,
        address quoter
    ) private pure {
        bytes memory body = new bytes(BODY_LEN);
        for (uint256 i; i < BODY_LEN; i++) {
            body[i] = signedQuote[i];
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            let sigStart := add(signedQuote, 132)
            r := mload(sigStart)
            s := mload(add(sigStart, 32))
            v := byte(0, mload(add(sigStart, 64)))
        }
        if (v < 27) v += 27;

        bytes32 rawDigest = keccak256(body);
        address recovered = ecrecover(rawDigest, v, r, s);
        // Defense-in-depth: even with a non-zero quoter, reject zero
        // recovered signers in every branch. ecrecover returns
        // address(0) on malformed sigs, and we never want that to
        // silently count as a successful match.
        if (recovered != address(0) && recovered == quoter) return;

        bytes32 prefixedDigest = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32", rawDigest
            )
        );
        recovered = ecrecover(prefixedDigest, v, r, s);
        if (recovered == address(0) || recovered != quoter) {
            revert QuoteSignatureInvalid();
        }
    }
}
