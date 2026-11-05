// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { WETH } from "lib/solmate/src/tokens/WETH.sol";

interface IExactTransferLib {
    function transferERC20ToUser(
        address token,
        uint256 amount
    ) external;

    function transferNativeToUser(
        uint256 amount
    ) external;

    function weth() external view returns (WETH);
}
