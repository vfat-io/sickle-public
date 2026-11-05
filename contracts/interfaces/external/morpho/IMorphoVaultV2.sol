// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.9;

/// @title IMorphoVaultV2
/// @notice Minimal subset of Morpho's `VaultV2` (an ERC-4626 vault) used by
/// `MorphoVaultV2Adapter`. The signatures are the standard ERC-4626 ones;
/// VaultV2 names the share owner `onBehalf`.
interface IMorphoVaultV2 {
    /// @notice The vault's underlying asset.
    function asset() external view returns (address);

    /// @notice Pulls `assets` from the caller and mints the resulting
    /// shares to `onBehalf`.
    function deposit(
        uint256 assets,
        address onBehalf
    ) external returns (uint256 shares);

    /// @notice Burns `shares` of `onBehalf` and sends the resulting assets
    /// to `receiver`. No allowance is needed when the caller is `onBehalf`.
    function redeem(
        uint256 shares,
        address receiver,
        address onBehalf
    ) external returns (uint256 assets);

    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares);

    function previewRedeem(
        uint256 shares
    ) external view returns (uint256 assets);
}

/// @title IMorphoVaultV2Factory
/// @notice Morpho's `VaultV2Factory`. It deploys every VaultV2 from fixed
/// bytecode and records each one, so `isVaultV2` authenticates a vault.
interface IMorphoVaultV2Factory {
    function isVaultV2(
        address vault
    ) external view returns (bool);
}
