// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { NftKey } from "contracts/structs/NftSettingsStructs.sol";
import { ISettingsModule } from "contracts/interfaces/ISettingsModule.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { Sickle } from "contracts/Sickle.sol";
import { ICLPool } from "contracts/interfaces/external/aerodrome/ICLPool.sol";

/**
 * @notice A stake-mode position's auto-flip policy. A zeroed mapping slot reads
 * back as `enabled = false`, which is the "not configured" signal.
 * @param pool the CL pool (immutable per vault)
 * @param aeroQuotePool external AERO/token1 pool for the AERO TWAP price;
 * unused (set 0) when AERO is one of the vault pool's own tokens
 * @param aero the AERO emission token, to orient the quote
 * @param twapWindow seconds for the TWAP used in pricing + fee conversion
 * @param dwellSeconds how long a flip candidate must persist (e.g. 6h)
 * @param feeWindowTarget target trailing fee window (e.g. 24h)
 * @param thetaUpBps unstake when R >= this (e.g. 12500 = 1.25x)
 * @param thetaDownBps restake when R <= this (e.g. 10000 = 1.0x)
 * @param enabled set true by the owner-keyed setter; the populated signal
 */
struct StakeConfig {
    address pool;
    address aeroQuotePool;
    address aero;
    uint32 twapWindow;
    uint32 dwellSeconds;
    uint32 feeWindowTarget;
    uint16 thetaUpBps;
    uint16 thetaDownBps;
    bool enabled;
}

/// @title StakeSettingsRegistry
/// @notice Typed, per-position settings for the Aerodrome stake-mode auto-flip
/// (`StakeStrategy`), kept out of the core `NftSettings` struct so the
/// feature ships without redeploying `NftSettingsRegistry` on every chain.
/// Registered as an `ISettingsModule` with `NftSettingsRegistry`, which drives
/// `onRebalance` so a position's policy survives the `tokenId` change a
/// rebalance mints.
/// @dev The same shape `MultiCompoundSettingsRegistry` uses — a new typed
/// registry per feature, no core struct change, no `bytes` blob. The vault (the
/// Sickle owner) writes via the owner-keyed setter; the strategy only reads.
contract StakeSettingsRegistry is ISettingsModule {
    /// ERRORS ///

    error NotSickleOwner();
    error OnlyNftSettingsRegistry();
    error InvalidConfig();

    /// EVENTS ///

    event ConfigSet(NftKey key, StakeConfig config);
    event ConfigUnset(NftKey key);

    /// STORAGE ///

    /// @notice Resolves a Sickle's owner, who is authorised to opt in.
    SickleFactory public immutable factory;
    /// @notice The core registry permitted to drive `onRebalance`.
    address public immutable nftSettingsRegistry;

    // Keyed by NftKey. `tokenId` is not rebalance-stable, so entries are
    // migrated by `onRebalance` when a rebalance mints a new tokenId.
    mapping(bytes32 => StakeConfig) configMap;

    constructor(
        SickleFactory factory_,
        address nftSettingsRegistry_
    ) {
        factory = factory_;
        nftSettingsRegistry = nftSettingsRegistry_;
    }

    /// @notice Opt a stake-mode position into the auto-flip policy.
    /// @custom:access Restricted to the Sickle owner (the vault).
    function setConfig(
        NftKey calldata key,
        StakeConfig calldata config
    ) external {
        _onlySickleOwner(key.sickle);
        if (
            config.pool == address(0) || config.aero == address(0)
                || config.feeWindowTarget == 0 || config.twapWindow == 0
                || config.thetaUpBps < config.thetaDownBps
        ) revert InvalidConfig();
        // AERO must be priceable in token1. When it is a vault-pool token the
        // pool itself quotes it (StakeStrategy._aeroPriceToken1 returns WAD for
        // token1, or reads cfg.pool for token0). Otherwise the configured quote
        // pool must pair AERO against the vault pool's token1, in either token
        // order — the exact assumption _aeroPriceToken1 relies on. A nonzero but
        // mispaired quote pool (e.g. AERO/WETH for a USDC-token1 vault) would
        // pass a bare presence check yet yield a wrong emission APR, so validate
        // the pairing here.
        address token1 = ICLPool(config.pool).token1();
        if (
            config.aero != ICLPool(config.pool).token0()
                && config.aero != token1
        ) {
            if (config.aeroQuotePool == address(0)) revert InvalidConfig();
            address q0 = ICLPool(config.aeroQuotePool).token0();
            address q1 = ICLPool(config.aeroQuotePool).token1();
            bool paired = (q0 == config.aero && q1 == token1)
                || (q0 == token1 && q1 == config.aero);
            if (!paired) revert InvalidConfig();
        }
        StakeConfig memory stored = config;
        stored.enabled = true; // the populated signal; presence == enabled
        configMap[keccak256(abi.encode(key))] = stored;
        emit ConfigSet(key, stored);
    }

    /// @notice Clear a stake-mode position's policy.
    /// @custom:access Restricted to the Sickle owner.
    function unsetConfig(
        NftKey calldata key
    ) external {
        _onlySickleOwner(key.sickle);
        delete configMap[keccak256(abi.encode(key))];
        emit ConfigUnset(key);
    }

    function getConfig(
        NftKey calldata key
    ) external view returns (StakeConfig memory) {
        return configMap[keccak256(abi.encode(key))];
    }

    /// @notice Migrate a position's policy when a rebalance changes its
    /// `tokenId`. A no-op for a position with no policy.
    /// @custom:access Restricted to `NftSettingsRegistry`, which calls this
    /// from `transferNftSettings`.
    function onRebalance(
        NftKey calldata oldKey,
        NftKey calldata newKey
    ) external {
        if (msg.sender != nftSettingsRegistry) {
            revert OnlyNftSettingsRegistry();
        }
        bytes32 oldHash = keccak256(abi.encode(oldKey));
        StakeConfig memory config = configMap[oldHash];
        if (!config.enabled) return; // no policy on this position — no-op
        configMap[keccak256(abi.encode(newKey))] = config;
        delete configMap[oldHash];
        emit ConfigUnset(oldKey);
        emit ConfigSet(newKey, config);
    }

    function _onlySickleOwner(
        Sickle sickle
    ) internal view {
        if (factory.admins(address(sickle)) != msg.sender) {
            revert NotSickleOwner();
        }
    }
}
