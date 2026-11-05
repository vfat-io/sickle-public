// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { NftKey } from "contracts/structs/NftSettingsStructs.sol";
import { PositionKey } from "contracts/structs/PositionSettingsStructs.sol";
import { BinKey } from "contracts/structs/BinSettingsStructs.sol";
import { ISettingsModule } from "contracts/interfaces/ISettingsModule.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { Sickle } from "contracts/Sickle.sol";

/// @title ExitDelaySettingsRegistry
/// @notice Per-position delay, in minutes, before an auto-exit fires: the
/// exit counterpart of `RebalanceConfig.delayMin`. Kept out of `ExitConfig`
/// so the feature ships without redeploying `NftSettingsRegistry`,
/// `PositionSettingsRegistry` or `BinSettingsRegistry`. Registered as an
/// `ISettingsModule` with `NftSettingsRegistry`, which drives `onRebalance`
/// so an NFT position's delay survives a `tokenId` change.
/// @dev ADVISORY, like `RebalanceConfig.delayMin`: the keeper enforces it
/// off-chain, and no `validateExitFor` reads it. Zero means no delay, and is
/// also what an unset position reads back as.
/// ERC20 and bin keys carry no `tokenId`, so a rebalance leaves them in place
/// and they need no migration. A bin move to a different pair or farm is a
/// new `BinKey`; the owner sets the delay again with the new settings.
/// Replacements inherit unwritten keys from `previousRegistry`. Explicit zero
/// writes mask predecessors, and recognized Sickles can transfer settings
/// atomically when migrating a position.
contract ExitDelaySettingsRegistry is ISettingsModule {
    /// ERRORS ///
    error NotSickleOwner();
    error OnlyNftSettingsRegistry();

    /// EVENTS ///

    event NftExitDelaySet(NftKey key, uint8 delayMin);
    event Erc20ExitDelaySet(PositionKey key, uint8 delayMin);
    event BinExitDelaySet(BinKey key, uint8 delayMin);

    /// STORAGE ///

    /// @notice Resolves a Sickle's owner, who is authorised to set delays.
    SickleFactory public immutable factory;
    /// @notice The core registry permitted to drive `onRebalance`.
    address public immutable nftSettingsRegistry;

    mapping(bytes32 => uint8) nftDelayMap;
    mapping(bytes32 => uint8) erc20DelayMap;
    mapping(bytes32 => uint8) binDelayMap;

    uint256 public constant MIGRATION_SETTINGS_VERSION = 1;
    ExitDelaySettingsRegistry public immutable previousRegistry;
    mapping(bytes32 => bool) private nftWritten;
    mapping(bytes32 => bool) private erc20Written;
    mapping(bytes32 => bool) private binWritten;

    error InvalidPredecessor();
    error OnlySickle();
    error InvalidMigrationKey();

    constructor(
        SickleFactory factory_,
        address nftSettingsRegistry_,
        ExitDelaySettingsRegistry previous_
    ) {
        factory = factory_;
        nftSettingsRegistry = nftSettingsRegistry_;
        if (address(previous_) != address(0)) {
            if (
                address(previous_).code.length == 0
                    || previous_.factory() != factory_
            ) revert InvalidPredecessor();
            NftKey memory probe;
            try previous_.getNftExitDelay(probe) returns (uint8) { }
            catch {
                revert InvalidPredecessor();
            }
        }
        previousRegistry = previous_;
    }

    /// @notice Set an NFT position's auto-exit delay. Zero clears it.
    /// @dev A write mined after a rebalance lands on the replaced `tokenId`
    /// and does not reach the live position; the caller re-reads the key.
    /// @custom:access Restricted to the Sickle owner.
    function setNftExitDelay(
        NftKey calldata key,
        uint8 delayMin
    ) external {
        _onlySickleOwner(key.sickle);
        _setNftDelay(key, delayMin);
    }

    /// @notice Set an ERC20 farm position's auto-exit delay. Zero clears it.
    /// @custom:access Restricted to the Sickle owner.
    function setErc20ExitDelay(
        PositionKey calldata key,
        uint8 delayMin
    ) external {
        _onlySickleOwner(key.sickle);
        _setErc20Delay(key, delayMin);
    }

    /// @notice Set a bin position's auto-exit delay. Zero clears it.
    /// @custom:access Restricted to the Sickle owner.
    function setBinExitDelay(
        BinKey calldata key,
        uint8 delayMin
    ) external {
        _onlySickleOwner(key.sickle);
        _setBinDelay(key, delayMin);
    }

    function getNftExitDelay(
        NftKey calldata key
    ) external view returns (uint8) {
        return _getNftDelay(key);
    }

    function getErc20ExitDelay(
        PositionKey calldata key
    ) external view returns (uint8) {
        return _getErc20Delay(key);
    }

    function getBinExitDelay(
        BinKey calldata key
    ) external view returns (uint8) {
        return _getBinDelay(key);
    }

    /// @notice Move an NFT position's delay when a rebalance changes its
    /// `tokenId`. A no-op for a position with no delay.
    /// @custom:access Restricted to `NftSettingsRegistry`, which calls this
    /// from `transferNftSettings`.
    function onRebalance(
        NftKey calldata oldKey,
        NftKey calldata newKey
    ) external {
        if (msg.sender != nftSettingsRegistry) {
            revert OnlyNftSettingsRegistry();
        }
        uint8 delayMin = _getNftDelay(oldKey);
        if (delayMin == 0) return;
        _setNftDelay(oldKey, 0);
        _setNftDelay(newKey, delayMin);
    }

    function migrateNftDelay(
        NftKey calldata oldKey,
        NftKey calldata newKey
    ) external {
        _checkKeys(oldKey.sickle, newKey);
        if (address(oldKey.nftManager) == address(0) || oldKey.tokenId == 0) {
            revert InvalidMigrationKey();
        }
        if (
            oldKey.nftManager == newKey.nftManager
                && oldKey.tokenId == newKey.tokenId
        ) revert InvalidMigrationKey();
        uint8 delayMin = _getNftDelay(oldKey);
        _setNftDelay(oldKey, 0);
        _setNftDelay(newKey, delayMin);
    }

    function migrateErc20Delay(
        PositionKey calldata oldKey,
        NftKey calldata newKey
    ) external {
        _checkKeys(oldKey.sickle, newKey);
        if (oldKey.stakingContract == address(0)) revert InvalidMigrationKey();
        uint8 delayMin = _getErc20Delay(oldKey);
        _setErc20Delay(oldKey, 0);
        _setNftDelay(newKey, delayMin);
    }

    function _checkKeys(
        Sickle sickle,
        NftKey calldata newKey
    ) private view {
        if (
            msg.sender != address(sickle)
                || factory.admins(msg.sender) == address(0)
        ) revert OnlySickle();
        if (
            newKey.sickle != sickle || address(newKey.nftManager) == address(0)
                || newKey.tokenId == 0
        ) revert InvalidMigrationKey();
    }

    function _getNftDelay(
        NftKey memory key
    ) internal view returns (uint8) {
        if (
            !nftWritten[keccak256(abi.encode(key))]
                && address(previousRegistry) != address(0)
        ) return previousRegistry.getNftExitDelay(key);
        return nftDelayMap[keccak256(abi.encode(key))];
    }

    function _getErc20Delay(
        PositionKey memory key
    ) internal view returns (uint8) {
        if (
            !erc20Written[keccak256(abi.encode(key))]
                && address(previousRegistry) != address(0)
        ) return previousRegistry.getErc20ExitDelay(key);
        return erc20DelayMap[keccak256(abi.encode(key))];
    }

    function _getBinDelay(
        BinKey memory key
    ) internal view returns (uint8) {
        if (
            !binWritten[keccak256(abi.encode(key))]
                && address(previousRegistry) != address(0)
        ) return previousRegistry.getBinExitDelay(key);
        return binDelayMap[keccak256(abi.encode(key))];
    }

    function _setNftDelay(
        NftKey memory key,
        uint8 delayMin
    ) internal {
        nftWritten[keccak256(abi.encode(key))] = true;
        nftDelayMap[keccak256(abi.encode(key))] = delayMin;
        emit NftExitDelaySet(key, delayMin);
    }

    function _setErc20Delay(
        PositionKey memory key,
        uint8 delayMin
    ) internal {
        erc20Written[keccak256(abi.encode(key))] = true;
        erc20DelayMap[keccak256(abi.encode(key))] = delayMin;
        emit Erc20ExitDelaySet(key, delayMin);
    }

    function _setBinDelay(
        BinKey memory key,
        uint8 delayMin
    ) internal {
        binWritten[keccak256(abi.encode(key))] = true;
        binDelayMap[keccak256(abi.encode(key))] = delayMin;
        emit BinExitDelaySet(key, delayMin);
    }

    function _onlySickleOwner(
        Sickle sickle
    ) internal view {
        if (factory.admins(address(sickle)) != msg.sender) {
            revert NotSickleOwner();
        }
    }
}
