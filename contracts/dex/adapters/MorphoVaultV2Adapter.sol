// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IMorphoVaultV2,
    IMorphoVaultV2Factory
} from "contracts/interfaces/external/morpho/IMorphoVaultV2.sol";

/// @title MorphoVaultV2Adapter
/// @notice Handles `DexType.MorphoVaultV2Deposit` (asset → vault shares via
/// `VaultV2.deposit`) and `DexType.MorphoVaultV2Redeem` (shares → asset via
/// `VaultV2.redeem`). Modelled on `AaveV3Adapter`: `SwapRouter` calls the
/// vault directly through `adapterCall`, so the minted shares or redeemed
/// assets land on the router and are measured by its balance delta. No
/// tokens ever transit this adapter.
///
/// Converting at the vault's own share price avoids the pool spread on the
/// thin secondary markets these shares trade in (Steakhouse steakUSDG on
/// Robinhood quoted about 20% below `previewDeposit` through aggregators).
///
/// @dev `step.router` is Morpho's `VaultV2Factory`; it must equal the
/// factory this adapter was deployed for, and `SwapRouter` additionally
/// requires it to be in the router allowlist, which is the on/off switch.
/// `step.dexData` must be empty: the vault is the share leg of the step
/// (`tokenOut` on deposit, `tokenIn` on redeem). The vault is authenticated
/// by the factory's `isVaultV2` registry rather than by any per-vault
/// allowlist entry, and its `asset()` must be the other leg. The factory
/// deploys every VaultV2 from fixed bytecode, so an authenticated vault
/// pulls exactly the approved assets on deposit and burns exactly the
/// router's shares on redeem.
///
/// A vault whose curator gates deposits or exits, or whose liquidity
/// adapter cannot cover a redemption, makes the vault call revert and the
/// whole swap with it.
contract MorphoVaultV2Adapter is DexAdapterBase {
    error InvalidDexType();
    error InvalidRouter();
    error InvalidDexData();
    error InvalidVault();
    error InvalidAsset();

    /// @notice The Morpho `VaultV2Factory` whose vaults this adapter serves.
    address public immutable VAULT_FACTORY;

    constructor(
        address admin_,
        address allowlist_,
        address vaultFactory_
    ) DexAdapterBase(admin_, allowlist_) {
        if (vaultFactory_ == address(0)) revert InvalidAddress();
        VAULT_FACTORY = vaultFactory_;
    }

    function version() external pure override returns (uint16) {
        return 1;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256) {
        if (step.router != VAULT_FACTORY) revert InvalidRouter();
        if (step.dexData.length != 0) revert InvalidDexData();

        if (step.dexType == uint8(DexType.MorphoVaultV2Deposit)) {
            address vault = step.tokenOut;
            // Prove the vault before approving it.
            _requireVault(vault, step.tokenIn);
            _adapterApprove(step.tokenIn, vault, amountIn);
            bytes memory result = _adapterCall(
                vault,
                0,
                abi.encodeCall(IMorphoVaultV2.deposit, (amountIn, msg.sender))
            );
            _adapterApprove(step.tokenIn, vault, 0);
            return abi.decode(result, (uint256));
        }

        if (step.dexType == uint8(DexType.MorphoVaultV2Redeem)) {
            address vault = step.tokenIn;
            _requireVault(vault, step.tokenOut);
            // No approval: `SwapRouter` is both caller and `onBehalf`, so the
            // vault burns its shares in place. Redeem the exact measured
            // amount so intermediate hops stay deterministic.
            bytes memory result = _adapterCall(
                vault,
                0,
                abi.encodeCall(
                    IMorphoVaultV2.redeem, (amountIn, msg.sender, msg.sender)
                )
            );
            return abi.decode(result, (uint256));
        }

        revert InvalidDexType();
    }

    /// @dev Require `vault` to be a VaultV2 deployed by `VAULT_FACTORY` whose
    /// underlying is `asset`.
    function _requireVault(
        address vault,
        address asset
    ) internal view {
        if (!IMorphoVaultV2Factory(VAULT_FACTORY).isVaultV2(vault)) {
            revert InvalidVault();
        }
        if (IMorphoVaultV2(vault).asset() != asset) revert InvalidAsset();
    }
}
