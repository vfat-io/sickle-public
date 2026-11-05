// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IGaugeManager {
    struct FarmingParam {
        address farmingCenter;
        address algebraEternalFarming;
        address nfpm;
    }

    function fetchInternalBribeFromPool(
        address _pool
    ) external returns (address);
    function fetchExternalBribeFromPool(
        address _pool
    ) external returns (address);
    function isGaugeAliveForPool(
        address _pool
    ) external returns (bool);
    function notifyRewardAmount(
        uint256 amount
    ) external;
    function distributeAll() external;
    function distributeFees() external;
    function minter() external view returns (address);
    function createGauge(
        address _pool,
        uint256 _gaugeType
    )
        external
        returns (
            address _gauge,
            address _internal_bribe,
            address _external_bribe
        );
    function gauges(
        address _pair
    ) external view returns (address);
    function isGauge(
        address _gauge
    ) external view returns (bool);
    function isCLGauge(
        address _gauge
    ) external view returns (bool);
    function poolForGauge(
        address _gauge
    ) external view returns (address);
    function internal_bribes(
        address _gauge
    ) external view returns (address);
    function external_bribes(
        address _gauge
    ) external view returns (address);
    function pools(
        uint256 i
    ) external view returns (address);
    function getBlackGovernor() external view returns (address);
    function setBlackGovernor(
        address _blackGovernor
    ) external;
    function acceptAlgebraFeeChangeProposal(
        uint16 newAlgebraFee
    ) external;
    function length() external view returns (uint256);
}
