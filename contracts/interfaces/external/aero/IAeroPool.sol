// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Values of IAeroPool.POOL_TYPE().
bytes32 constant AERO_V2_STABLE = "V2_STABLE";
bytes32 constant AERO_V2_VOLATILE = "V2_VOLATILE";
bytes32 constant AERO_CL = "CL";

interface IAeroPool {
    function claimFees(
        address recipient
    ) external returns (uint256 amount0, uint256 amount1);

    function POOL_TYPE() external view returns (bytes32);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);

    /// @return dec0 10 ** token0.decimals()
    /// @return dec1 10 ** token1.decimals()
    function metadata()
        external
        view
        returns (
            uint256 dec0,
            uint256 dec1,
            uint256 r0,
            uint256 r1,
            address t0,
            address t1
        );

    function mint(
        address to
    ) external returns (uint256 liquidity);

    function burn(
        address to
    ) external returns (uint256 amount0, uint256 amount1);
}
