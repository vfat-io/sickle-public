// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Aero (Dromos MetaDEX) Metarouter — the venue's batch executor,
/// shaped like a Uniswap UniversalRouter: one `commands` byte string paired
/// with one ABI-encoded input per command.
///
/// Only the exact-input swap surface is declared. The Metarouter's remaining
/// commands (liquidity, gauge staking, cross-chain redeem) are not part of the
/// swap path and are deliberately left out rather than mirrored speculatively.
interface IAeroMetarouter {
    /// @notice How a command resolves the amount it spends.
    /// @dev `Amount` is an exact token amount. `Pips` is a share of the
    /// Metarouter's own balance and is therefore only meaningful when the
    /// Metarouter is the payer — a `payerIsUser` route rejects it, because a
    /// percentage of somebody else's wallet has no defined meaning.
    enum SpendMode {
        Amount,
        Pips
    }

    struct BalanceSpend {
        SpendMode mode;
        uint256 value;
    }

    /// @notice Inputs for `V2_SWAP_EXACT_IN` (0x08) and `CL_SWAP_EXACT_IN`
    /// (0x00).
    /// @param pools Forward-ordered pools in the route. The Metarouter proves
    /// each one against `FactoryRegistry.targetToFactory` plus the owning
    /// factory's `isPool`, and rejects any pool outside the route's family, so
    /// the route is validated on-chain rather than trusted from calldata.
    /// @param tokenIn Input token for the first pool.
    /// @param amountIn Spend selection for the route input.
    /// @param payerIsUser Whether the Metarouter pulls the input from its
    /// caller by `transferFrom` instead of spending its own balance.
    /// @param minAmountOut Minimum output the recipient must receive.
    /// @param recipient Address that receives the final output.
    struct SwapExactInParams {
        address[] pools;
        address tokenIn;
        BalanceSpend amountIn;
        bool payerIsUser;
        uint256 minAmountOut;
        address recipient;
    }

    /// @notice Runs one batch of commands.
    /// @dev The caller becomes the batch's logical sender, which is the account
    /// a `payerIsUser` route pulls from.
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}
