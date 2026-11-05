// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "lib/solmate/src/utils/SafeTransferLib.sol";
import { WETH } from "lib/solmate/src/tokens/WETH.sol";
import { Sickle } from "contracts/Sickle.sol";
import {
    IExactTransferLib
} from "contracts/interfaces/libraries/IExactTransferLib.sol";

contract ExactTransferLib is IExactTransferLib {
    WETH public immutable weth;

    constructor(
        WETH weth_
    ) {
        weth = weth_;
    }

    /// @dev Transfers exactly {amount} ERC20 tokens from the delegatecalling
    /// Sickle to the Sickle owner.
    function transferERC20ToUser(
        address token,
        uint256 amount
    ) external {
        if (amount == 0) return;

        address recipient = Sickle(payable(address(this))).owner();
        SafeTransferLib.safeTransfer(token, recipient, amount);
    }

    /// @dev Unwraps exactly {amount} WETH from the delegatecalling Sickle and
    /// sends the native token to the Sickle owner.
    function transferNativeToUser(
        uint256 amount
    ) external {
        if (amount == 0) return;

        address recipient = Sickle(payable(address(this))).owner();
        weth.withdraw(amount);
        SafeTransferLib.safeTransferETH(recipient, amount);
    }
}
