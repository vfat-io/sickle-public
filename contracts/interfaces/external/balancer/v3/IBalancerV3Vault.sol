// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Balancer V3 `HooksConfig`. Field order pinned against the Bush
/// (Balancer V3 fork) Vault on Robinhood 4663
/// (0xB055000fbE3cc9bDE7742C583a86cc6283E3fF85,
/// `@bush/v3-interfaces/contracts/vault/VaultTypes.sol`).
struct BalancerV3HooksConfig {
    bool enableHookAdjustedAmounts;
    bool shouldCallBeforeInitialize;
    bool shouldCallAfterInitialize;
    bool shouldCallComputeDynamicSwapFee;
    bool shouldCallBeforeSwap;
    bool shouldCallAfterSwap;
    bool shouldCallBeforeAddLiquidity;
    bool shouldCallAfterAddLiquidity;
    bool shouldCallBeforeRemoveLiquidity;
    bool shouldCallAfterRemoveLiquidity;
    address hooksContract;
}

/// @notice Balancer V3 `TokenInfo` (`TokenType` is `STANDARD = 0`,
/// `WITH_RATE = 1`).
struct BalancerV3TokenInfo {
    uint8 tokenType;
    address rateProvider;
    bool paysYieldFees;
}

/// @notice Read-only subset of the Balancer V3 Vault. The pool views are
/// served by `VaultExtension` through the Vault's delegatecall fallback and
/// revert `PoolNotRegistered` for an unregistered pool.
interface IBalancerV3Vault {
    function getPoolTokens(
        address pool
    ) external view returns (address[] memory tokens);

    function getPoolTokenInfo(
        address pool
    )
        external
        view
        returns (
            address[] memory tokens,
            BalancerV3TokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        );

    function getCurrentLiveBalances(
        address pool
    ) external view returns (uint256[] memory balancesLiveScaled18);

    function getHooksConfig(
        address pool
    ) external view returns (BalancerV3HooksConfig memory);

    function totalSupply(
        address token
    ) external view returns (uint256);

    function getReservesOf(
        address token
    ) external view returns (uint256);
}
