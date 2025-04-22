// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SickleRegistry } from "contracts/SickleRegistry.sol";
import { Sickle } from "contracts/Sickle.sol";
import { Admin } from "contracts/base/Admin.sol";

/// @title SickleFactory contract
/// @author vfat.tools
/// @notice Factory deploying new Sickle contracts
contract SickleFactory is Admin {
    /// EVENTS ///

    /// @notice Emitted when a new Sickle contract is deployed
    /// @param owner Address that owns the Sickle contract
    /// @param sickle Address of the newly deployed Sickle contract
    event Deploy(address indexed owner, address sickle);

    /// @notice Thrown when the caller is not whitelisted
    /// @param caller Address of the non-whitelisted caller
    error CallerNotWhitelisted(address caller); // 0x252c8273

    /// @notice Thrown when the factory is not active and a deploy is attempted
    error NotActive(); // 0x80cb55e2

    /// @notice Thrown when a Sickle contract is already deployed for a user
    error SickleAlreadyDeployed(); //0xf6782ef1

    /// STORAGE ///

    mapping(address => address) private _sickles;
    mapping(address => address) private _owners;
    mapping(address => bytes32) private _referralCodes;

    /// @notice Address of the SickleRegistry contract
    SickleRegistry public immutable registry;

    /// @notice Address of the Sickle implementation contract
    address public immutable implementation;

    /// @notice Address of the previous SickleFactory contract (if applicable)
    SickleFactory public immutable previousFactory;

    /// @notice Whether the factory is active (can deploy new Sickle contracts)
    bool public isActive = true;

    /// WRITE FUNCTIONS ///

    /// @param admin_ Address of the admin
    /// @param sickleRegistry_ Address of the SickleRegistry contract
    /// @param sickleImplementation_ Address of the Sickle implementation
    /// contract
    /// @param previousFactory_ Address of the previous SickleFactory contract
    /// if applicable
    constructor(
        address admin_,
        address sickleRegistry_,
        address sickleImplementation_,
        address previousFactory_
    ) Admin(admin_) {
        registry = SickleRegistry(sickleRegistry_);
        implementation = sickleImplementation_;
        previousFactory = SickleFactory(previousFactory_);
    }

    /// @notice Update the isActive flag.
    /// @dev Effectively pauses and unpauses new Sickle deployments.
    /// @custom:access Restricted to protocol owner.
    function setActive(
        bool active
    ) external onlyAdmin {
        isActive = active;
    }

    function _deploy(
        address owner,
        address approved,
        bytes32 referralCode
    ) internal returns (address sickle) {
        sickle = Clones.cloneDeterministic(
            implementation, keccak256(abi.encode(owner))
        );
        Sickle(payable(sickle)).initialize(owner, approved);
        _sickles[owner] = sickle;
        _owners[sickle] = owner;
        if (referralCode != bytes32(0)) {
            _referralCodes[sickle] = referralCode;
        }
        emit Deploy(owner, sickle);
    }

    function _getSickle(
        address owner
    ) internal returns (address sickle) {
        sickle = _sickles[owner];
        if (sickle != address(0)) {
            return sickle;
        }
        if (address(previousFactory) != address(0)) {
            sickle = previousFactory.sickles(owner);
            if (sickle != address(0)) {
                _sickles[owner] = sickle;
                _owners[sickle] = owner;
                _referralCodes[sickle] = previousFactory.referralCodes(sickle);
                return sickle;
            }
        }
    }

    /// @notice Predict the address of a Sickle contract for a specific user
    /// @param owner Address that owns the Sickle contract
    /// @return sickle Address of the predicted Sickle contract
    function predict(
        address owner
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(owner));
        return Clones.predictDeterministicAddress(implementation, salt);
    }

    /// @notice Returns the Sickle contract for a specific user
    /// @param owner Address that owns the Sickle contract
    /// @return sickle Address of the Sickle contract
    function sickles(
        address owner
    ) external view returns (address sickle) {
        sickle = _sickles[owner];
        if (sickle == address(0) && address(previousFactory) != address(0)) {
            sickle = previousFactory.sickles(owner);
        }
    }

    /// @notice Returns the owner for a specific Sickle contract
    /// @param sickle Address of the Sickle contract
    /// @return owner Address that owns the Sickle contract
    function owners(
        address sickle
    ) external view returns (address owner) {
        owner = _owners[sickle];
        if (owner == address(0) && address(previousFactory) != address(0)) {
            owner = previousFactory.owners(sickle);
        }
    }

    /// @notice Returns the referral code for a specific Sickle contract
    /// @param sickle Address of the Sickle contract
    /// @return referralCode Referral code for the user
    function referralCodes(
        address sickle
    ) external view returns (bytes32 referralCode) {
        referralCode = _referralCodes[sickle];
        if (
            referralCode == bytes32(0) && address(previousFactory) != address(0)
        ) {
            referralCode = previousFactory.referralCodes(sickle);
        }
    }

    /// @notice Deploys a new Sickle contract for a specific user, or returns
    /// the existing one if it exists
    /// @param owner Address that owns the Sickle contract
    /// @param approved Address that is approved to call automation functions
    /// for the Sickle
    /// @param referralCode Referral code for the user
    /// @return sickle Address of the deployed Sickle contract
    function getOrDeploy(
        address owner,
        address approved,
        bytes32 referralCode
    ) external returns (address sickle) {
        if (!isActive) {
            revert NotActive();
        }
        if (!registry.isWhitelistedCaller(msg.sender)) {
            revert CallerNotWhitelisted(msg.sender);
        }
        if ((sickle = _getSickle(owner)) != address(0)) {
            return sickle;
        }
        return _deploy(owner, approved, referralCode);
    }

    /// @notice Deploys a new Sickle contract for a specific user
    /// @dev Sickle contracts are deployed with create2, the address of the
    /// owner is used as a salt, so all the Sickle addresses can be pre-computed
    /// and only 1 Sickle will exist per address
    /// @param approved Address that is approved to call automation functions
    /// for the Sickle
    /// @param referralCode Referral code for the user
    /// @return sickle Address of the deployed Sickle contract
    function deploy(
        address approved,
        bytes32 referralCode
    ) external returns (address sickle) {
        if (!isActive) {
            revert NotActive();
        }
        if (_getSickle(msg.sender) != address(0)) {
            revert SickleAlreadyDeployed();
        }
        return _deploy(msg.sender, approved, referralCode);
    }
}
