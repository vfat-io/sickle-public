// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IKodiakIslandPool {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(
        address owner
    ) external view returns (uint256);
    function burn(
        uint256 burnAmount,
        address receiver
    )
        external
        returns (uint256 amount0, uint256 amount1, uint128 liquidityBurned);
    function compounderSlippageBPS() external view returns (uint16);
    function compounderSlippageInterval() external view returns (uint32);
    function decimals() external view returns (uint8);
    function executiveRebalance(
        int24 newLowerTick,
        int24 newUpperTick,
        uint160 swapThresholdPrice,
        uint256 swapAmountBPS,
        bool zeroForOne
    ) external;

    struct SwapData {
        address router;
        uint256 amountIn;
        uint256 minAmountOut;
        bool zeroForOne;
        bytes routeData;
    }

    function executiveRebalanceWithRouter(
        int24 newLowerTick,
        int24 newUpperTick,
        SwapData calldata swapData
    ) external;
    function getAvgPrice(
        uint32 interval
    ) external view returns (uint160 avgSqrtPriceX96);
    function getMintAmounts(
        uint256 amount0Max,
        uint256 amount1Max
    )
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 mintAmount);
    function getPositionID() external view returns (bytes32 positionID);
    function getUnderlyingBalances()
        external
        view
        returns (uint256 amount0Current, uint256 amount1Current);
    function getUnderlyingBalancesAtPrice(
        uint160 sqrtRatioX96
    ) external view returns (uint256 amount0Current, uint256 amount1Current);
    function initialize(
        string calldata _name,
        string calldata _symbol,
        address _pool,
        uint16 _managerFeeBPS,
        int24 _lowerTick,
        int24 _upperTick,
        address _manager_,
        address _managerTreasury
    ) external;

    function isManaged() external view returns (bool);
    function islandFactory() external view returns (address);
    function lowerTick() external view returns (int24);
    function manager() external view returns (address);
    function managerBalance0() external view returns (uint256);
    function managerBalance1() external view returns (uint256);
    function managerFeeBPS() external view returns (uint16);
    function managerTreasury() external view returns (address);
    function mint(
        uint256 mintAmount,
        address receiver
    )
        external
        returns (uint256 amount0, uint256 amount1, uint128 liquidityMinted);
    function name() external view returns (string memory);
    function nonces(
        address owner
    ) external view returns (uint256);
    function pause() external;
    function paused() external view returns (bool);
    function pauser(
        address
    ) external view returns (bool);
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    function pool() external view returns (address);
    function rebalance() external;
    function renounceOwnership() external;
    function restrictedMint() external view returns (bool);
    function setPauser(address _pauser, bool _status) external;
    function setRestrictedMint(
        bool _status
    ) external;
    function setRouter(address _router, bool _status) external;
    function swapRouter(
        address
    ) external view returns (bool);
    function symbol() external view returns (string memory);
    function syncToFactory() external;
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
    function transferOwnership(
        address newOwner
    ) external;
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external;
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
    function unpause() external;
    function updateManagerParams(
        int16 newManagerFeeBPS,
        address newManagerTreasury,
        int16 newSlippageBPS,
        int32 newSlippageInterval
    ) external;
    function upperTick() external view returns (int24);
    function version() external view returns (string memory);
    function withdrawManagerBalance() external;
    function worstAmountOut(
        uint256 amountIn,
        uint16 slippageBPS,
        uint160 avgSqrtPriceX96,
        bool zeroForOne
    ) external pure returns (uint256);
}
