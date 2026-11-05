// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILBPair {
    struct MintArrays {
        uint256[] ids;
        bytes32[] amounts;
        uint256[] liquidityMinted;
    }

    function getTokenX() external view returns (IERC20);

    function getTokenY() external view returns (IERC20);

    function getFactory() external view returns (address);

    function getBinStep() external pure returns (uint16);

    function getActiveId() external view returns (uint24);

    function getReserves()
        external
        view
        returns (uint128 reserveX, uint128 reserveY);

    function getBin(
        uint24 id
    ) external view returns (uint128 binReserveX, uint128 binReserveY);

    function getNextNonEmptyBin(
        bool swapForY,
        uint24 id
    ) external view returns (uint24);

    function getOracleParameters()
        external
        view
        returns (
            uint8 sampleLifetime,
            uint16 size,
            uint16 activeSize,
            uint40 lastUpdated,
            uint40 firstTimestamp
        );

    function getOracleSampleAt(
        uint40 lookupTimestamp
    )
        external
        view
        returns (
            uint64 cumulativeId,
            uint64 cumulativeVolatility,
            uint64 cumulativeBinCrossed
        );

    function getPriceFromId(
        uint24 id
    ) external pure returns (uint256);

    function getIdFromPrice(
        uint256 price
    ) external pure returns (uint24);

    function getSwapIn(
        uint128 amountOut,
        bool swapForY
    )
        external
        view
        returns (uint128 amountIn, uint128 amountOutLeft, uint128 fee);

    function getSwapOut(
        uint128 amountIn,
        bool swapForY
    )
        external
        view
        returns (uint128 amountInLeft, uint128 amountOut, uint128 fee);

    function swap(
        bool swapForY,
        address to
    ) external returns (bytes32 amountsOut);

    function flashLoan(
        address receiver,
        bytes32 amounts,
        bytes calldata data
    ) external;

    function mint(
        address to,
        bytes32[] calldata liquidityConfigs,
        address refundTo
    )
        external
        returns (
            bytes32 amountsReceived,
            bytes32 amountsLeft,
            uint256[] memory liquidityMinted
        );

    function burn(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amountsToBurn
    ) external returns (bytes32[] memory amounts);

    function collectProtocolFees()
        external
        returns (bytes32 collectedProtocolFees);

    function balanceOf(
        address account,
        uint256 id
    ) external view returns (uint256);

    function balanceOfBatch(
        address[] calldata accounts,
        uint256[] calldata ids
    ) external view returns (uint256[] memory);

    function isApprovedForAll(
        address owner,
        address spender
    ) external view returns (bool);

    function approveForAll(
        address spender,
        bool approved
    ) external;

    function batchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external;

    function totalSupply(
        uint256 id
    ) external view returns (uint256);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);
}
