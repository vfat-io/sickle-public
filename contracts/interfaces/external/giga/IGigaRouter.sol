// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Apex Classic liquidity router interface
/// @notice Note: every liquidity entrypoint takes a STRUCT, not flat arguments.
///         Solidly/Velodrome-style flat-argument calls will hit no selector and
///         revert with empty returndata.
interface IGigaRouter {
    struct AddLiquidityParams {
        address tokenA;
        address tokenB;
        bool stable;
        uint256 amountADesired;
        uint256 amountBDesired;
        uint256 amountAMin;
        uint256 amountBMin;
        address to;
        uint256 deadline;
    }

    struct AddLiquidityETHParams {
        address token;
        bool stable;
        uint256 amountTokenDesired;
        uint256 amountTokenMin;
        uint256 amountETHMin;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        address tokenA;
        address tokenB;
        bool stable;
        uint256 liquidity;
        uint256 amountAMin;
        uint256 amountBMin;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityETHParams {
        address token;
        bool stable;
        uint256 liquidity;
        uint256 amountTokenMin;
        uint256 amountETHMin;
        address to;
        uint256 deadline;
    }

    event RemoveLiquidityFromStake(
        address indexed account,
        address indexed pair,
        uint256 indexed pid,
        uint256 liquidity,
        uint256 amountA,
        uint256 amountB
    );

    event RemoveLiquidityETHFromStake(
        address indexed account,
        address indexed pair,
        uint256 indexed pid,
        uint256 liquidity,
        uint256 amountToken,
        uint256 amountETH
    );

    /* -------------------------------------------------------------------- */
    /*                               Constants                              */
    /* -------------------------------------------------------------------- */

    function WITHDRAW_CALLBACK_REMOVE_LIQUIDITY() external view returns (uint8);

    function WITHDRAW_CALLBACK_REMOVE_LIQUIDITY_ETH()
        external
        view
        returns (uint8);

    /* -------------------------------------------------------------------- */
    /*                              Immutables                              */
    /* -------------------------------------------------------------------- */

    function classicFactory() external view returns (address);

    function classicChef() external view returns (address);

    function WETH9() external view returns (address);

    /* -------------------------------------------------------------------- */
    /*                                 Views                                */
    /* -------------------------------------------------------------------- */

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getReserves(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (uint256 reserveA, uint256 reserveB);

    /* -------------------------------------------------------------------- */
    /*                                 Pairs                                */
    /* -------------------------------------------------------------------- */

    /// @dev Not a view: deploys the pair if it does not exist yet.
    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair);

    /* -------------------------------------------------------------------- */
    /*                             Add liquidity                            */
    /* -------------------------------------------------------------------- */

    /// @dev selector 0xbc92cd72
    function addLiquidity(
        AddLiquidityParams calldata params
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @dev selector 0x2de6e7b1
    function addLiquidityETH(
        AddLiquidityETHParams calldata params
    )
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    /// @dev selector 0xb8abec53
    function addLiquidityAndStake(
        AddLiquidityParams calldata params
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function addLiquidityETHAndStake(
        AddLiquidityETHParams calldata params
    )
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    /* -------------------------------------------------------------------- */
    /*                           Remove liquidity                           */
    /* -------------------------------------------------------------------- */

    /// @dev selector 0xa8261ac3
    function removeLiquidity(
        RemoveLiquidityParams calldata params
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETH(
        RemoveLiquidityETHParams calldata params
    ) external returns (uint256 amountToken, uint256 amountETH);

    /* -------------------------------------------------------------------- */
    /*                            Chef callback                             */
    /* -------------------------------------------------------------------- */

    /// @notice Called by the ClassicChef on withdraw. `data` is
    ///         abi.encode(uint8 action, RemoveLiquidityParams) or
    ///         abi.encode(uint8 action, RemoveLiquidityETHParams).
    function onClassicChefWithdraw(
        address account,
        uint256 pid,
        uint256 amount,
        bytes calldata data
    ) external;
}
