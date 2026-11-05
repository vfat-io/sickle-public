// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.9;

/// @title IAaveV3Pool
/// @notice Minimal subset of the Aave v3 `Pool` (a.k.a. `LendingPool`)
/// interface used by `AaveV3Adapter`: supplying an underlying asset to
/// mint aTokens and withdrawing an underlying asset by burning aTokens.
interface IAaveV3Pool {
    /// @notice Supplies `amount` of `asset`, minting the corresponding
    /// aToken to `onBehalfOf`. Requires `asset` approval to the Pool.
    /// @param asset The underlying ERC20 being supplied.
    /// @param amount The amount of underlying to supply.
    /// @param onBehalfOf The address that receives the minted aTokens.
    /// @param referralCode Aave referral code (0 for none).
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /// @notice Withdraws `amount` of `asset`, burning the caller's
    /// aTokens and sending the underlying to `to`. Passing
    /// `type(uint256).max` withdraws the caller's entire balance.
    /// @param asset The underlying ERC20 being withdrawn.
    /// @param amount The amount of underlying to withdraw.
    /// @param to The recipient of the withdrawn underlying.
    /// @return The final amount of underlying withdrawn.
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}
