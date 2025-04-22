// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IKodiakIslandPoolFactory {
    // Events
    event IslandCreated(
        address indexed uniPool,
        address indexed manager,
        address indexed island,
        address implementation
    );

    event IslandFeeSet(uint16 fee);
    event OwnershipTransferred(
        address indexed previousOwner, address indexed newOwner
    );
    event TreasurySet(address indexed treasury);
    event UpdateIslandImplementation(address newImplementation);

    // Functions
    function deployVault(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        address manager,
        address managerTreasury,
        uint16 managerFee,
        int24 lowerTick,
        int24 upperTick
    ) external returns (address island);

    function factory() external view returns (address);

    function getDeployers() external view returns (address[] memory);

    function getIslands(
        address deployer
    ) external view returns (address[] memory islands);

    function getSymbols(
        address token0,
        address token1
    ) external view returns (string memory res);

    function islandFee() external view returns (uint16);

    function islandImplementation() external view returns (address);

    function numDeployers() external view returns (uint256);

    function numIslands(
        address deployer
    ) external view returns (uint256);

    function numIslands() external view returns (uint256 result);

    function owner() external view returns (address);

    function renounceOwnership() external;

    function setIslandFee(
        uint16 _islandFee
    ) external;

    function setIslandImplementation(
        address _implementation
    ) external;

    function setTreasury(
        address _treasury
    ) external;

    function transferOwnership(
        address newOwner
    ) external;

    function treasury() external view returns (address);
}
