// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IRouterAllowlist } from "contracts/interfaces/IRouterAllowlist.sol";
import {
    IMorphoVaultV2,
    IMorphoVaultV2Factory
} from "contracts/interfaces/external/morpho/IMorphoVaultV2.sol";
import {
    SingleAssetVaultConnector
} from "contracts/connectors/single-asset-vault/SingleAssetVaultConnector.sol";

interface IMorphoVaultV2RecordedAssets {
    function _totalAssets() external view returns (uint128);
}

/// @notice Factory-authenticated Morpho VaultV2 implementation of the category.
/// @dev Every canonical factory vault resolves without individual vault or
/// asset permissions. Its ERC4626 asset is read from the authenticated vault.
/// Morpho's standard ERC20 assumptions apply; taxed/rebasing assets are
/// unsupported, and observed execution balance mismatches revert.
contract MorphoVaultV2Connector is SingleAssetVaultConnector {
    error InvalidConfiguration();

    address public immutable VAULT_FACTORY;
    IRouterAllowlist public immutable allowlist;

    constructor(
        address factory_,
        IRouterAllowlist allowlist_
    ) {
        if (factory_.code.length == 0 || address(allowlist_).code.length == 0) {
            revert InvalidConfiguration();
        }
        VAULT_FACTORY = factory_;
        allowlist = allowlist_;
    }

    function isVault(
        address vault
    ) public view override returns (bool) {
        if (vault.code.length == 0 || !allowlist.isAllowed(VAULT_FACTORY)) {
            return false;
        }
        if (!IMorphoVaultV2Factory(VAULT_FACTORY).isVaultV2(vault)) {
            return false;
        }
        address asset = IMorphoVaultV2(vault).asset();
        return asset.code.length != 0 && IERC20Metadata(asset).decimals() <= 18;
    }

    function _asset(
        address vault
    ) internal view override returns (address) {
        allowlist.requireAllowed(VAULT_FACTORY);
        if (
            vault.code.length == 0
                || !IMorphoVaultV2Factory(VAULT_FACTORY).isVaultV2(vault)
        ) {
            revert InvalidVault();
        }
        address asset = IMorphoVaultV2(vault).asset();
        if (asset.code.length == 0 || IERC20Metadata(asset).decimals() > 18) {
            revert InvalidAsset();
        }
        return asset;
    }

    function _recordedAssets(
        address vault
    ) internal view override returns (uint256) {
        return IMorphoVaultV2RecordedAssets(vault)._totalAssets();
    }
}
