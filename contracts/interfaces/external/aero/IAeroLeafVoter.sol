// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Aero (Dromos MetaDEX) `FactoryRegistry`, reduced to gauge
/// enumeration and the gauge to rewards-manager lookup.
/// @dev Declared from the verified ABI of the Base deployment
/// (0x7b2A2c12dC5Ea2a31455952a05031C3E4BB28F3E).
interface IAeroFactoryRegistry {
    function leafVoter() external view returns (address);

    function gaugeFactories() external view returns (address[] memory);

    function factoryToGauges(
        address factory
    ) external view returns (address[] memory);

    function gaugeToRewards(
        address gauge
    ) external view returns (address);
}

/// @notice Aero (Dromos MetaDEX) `LeafVoter`, reduced to its registry.
/// @dev Declared from the verified ABI of the Base deployment
/// (0x382409fad8503FbCdbB27A4211551fa03e884078).
interface IAeroLeafVoter {
    function FACTORY_REGISTRY() external view returns (IAeroFactoryRegistry);
}
