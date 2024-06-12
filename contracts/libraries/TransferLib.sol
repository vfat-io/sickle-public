// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { MsgValueModule } from "contracts/modules/MsgValueModule.sol";
import { WETH } from "lib/solmate/src/tokens/WETH.sol";
import { Sickle } from "contracts/Sickle.sol";
import { SafeTransferLib } from "lib/solmate/src/utils/SafeTransferLib.sol";
import { IERC20 } from
    "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { FeesLib } from "contracts/libraries/FeesLib.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";

contract TransferLib is MsgValueModule, DelegateModule {
    error ArrayLengthMismatch();
    error TokenInRequired();

    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    WETH public immutable weth;

    FeesLib public immutable feesLib;

    constructor(FeesLib feseLib_, WETH weth_) {
        feesLib = feseLib_;
        weth = weth_;
    }

    /// @dev Transfers the balance of {token} from the contract to the
    /// sickle owner
    /// @param token Address of the token to transfer
    function transferTokenToUser(address token) public payable {
        address recipient = Sickle(payable(address(this))).owner();
        if (token == address(0)) {
            return;
        }
        if (token == ETH) {
            uint256 wethBalance = weth.balanceOf(address(this));
            if (wethBalance > 0) {
                weth.withdraw(wethBalance);
            }
            if (address(this).balance > 0) {
                SafeTransferLib.safeTransferETH(
                    recipient, address(this).balance
                );
            }
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                SafeTransferLib.safeTransfer(token, recipient, balance);
            }
        }
    }

    /// @dev Transfers all balances of {tokens} and/or ETH from the contract
    /// to the sickle owner
    /// @param tokens An array of token addresses
    function transferTokensToUser(address[] memory tokens) external payable {
        for (uint256 i = 0; i != tokens.length;) {
            transferTokenToUser(tokens[i]);

            unchecked {
                i++;
            }
        }
    }

    /// @dev Transfers {amountIn} of {tokenIn} from the user to the Sickle
    /// contract, charging the fees and converting the amount to WETH if
    /// necessary
    /// @param tokenIn Address of the token to transfer
    /// @param amountIn Amount of the token to transfer
    /// @param strategy Address of the caller strategy
    /// @param feeSelector Selector of the caller function
    function transferTokenFromUser(
        address tokenIn,
        uint256 amountIn,
        address strategy,
        bytes4 feeSelector
    ) public payable {
        _checkMsgValue(amountIn, tokenIn == ETH);

        _transferTokenFromUser(tokenIn, amountIn, strategy, feeSelector);
    }

    /// @dev Transfers {amountIn} of {tokenIn} from the user to the Sickle
    /// contract, charging the fees and converting the amount to WETH if
    /// necessary
    /// @param tokensIn Addresses of the tokens to transfer
    /// @param amountsIn Amounts of the tokens to transfer
    /// @param strategy Address of the caller strategy
    /// @param feeSelector Selector of the caller function
    function transferTokensFromUser(
        address[] memory tokensIn,
        uint256[] memory amountsIn,
        address strategy,
        bytes4 feeSelector
    ) external payable {
        if (tokensIn.length != amountsIn.length) {
            revert ArrayLengthMismatch();
        }
        if (tokensIn.length == 0) {
            revert TokenInRequired();
        }
        bool hasEth = false;

        for (uint256 i = 0; i < tokensIn.length; i++) {
            if (tokensIn[i] == ETH) {
                _checkMsgValue(amountsIn[i], true);
                hasEth = true;
            }
            _transferTokenFromUser(
                tokensIn[i], amountsIn[i], strategy, feeSelector
            );
        }

        if (!hasEth) {
            // Revert if ETH was sent but not used
            _checkMsgValue(0, false);
        }
    }

    /* Internal functions */

    function _transferTokenFromUser(
        address tokenIn,
        uint256 amountIn,
        address strategy,
        bytes4 feeSelector
    ) internal {
        if (tokenIn != ETH) {
            SafeTransferLib.safeTransferFrom(
                tokenIn,
                Sickle(payable(address(this))).owner(),
                address(this),
                amountIn
            );
        }

        bytes memory result = _delegateTo(
            address(feesLib),
            abi.encodeCall(
                FeesLib.chargeFee, (strategy, feeSelector, tokenIn, 0)
            )
        );
        uint256 remainder = abi.decode(result, (uint256));

        if (tokenIn == ETH) {
            weth.deposit{ value: remainder }();
        }
    }
}
