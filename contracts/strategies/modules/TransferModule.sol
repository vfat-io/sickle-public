// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./AccessControlModule.sol";
import "./FeesModule.sol";
import "./MsgValueModule.sol";

contract TransferModule is AccessControlModule, FeesModule, MsgValueModule {
    error ArrayLengthMismatch();
    error TokenInRequired();

    constructor(
        SickleFactory factory_,
        FeesLib feesLib_,
        address wrappedNativeAddress_
    )
        FeesModule(feesLib_, wrappedNativeAddress_)
        AccessControlModule(factory_)
    { }

    /// @dev Transfers the balance of {token} from the contract to the
    /// sickle owner
    /// @param token Address of the token to transfer
    function _sickle_transfer_token_to_user(address token)
        public
        payable
        onlyRegisteredSickle
    {
        address recipient = Sickle(payable(address(this))).owner();
        if (token == address(0)) {
            return;
        }
        if (token == ETH) {
            uint256 wethBalance =
                IWETH9(wrappedNativeAddress).balanceOf(address(this));
            if (wethBalance > 0) {
                IWETH9(wrappedNativeAddress).withdraw(wethBalance);
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
    function _sickle_transfer_tokens_to_user(address[] memory tokens)
        external
        payable
        onlyRegisteredSickle
    {
        for (uint256 i = 0; i != tokens.length; i++) {
            _sickle_transfer_token_to_user(tokens[i]);
        }
    }

    function _transfer_token_from_user(
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

        amountIn = _charge_fees(
            keccak256(abi.encodePacked(strategy, feeSelector)),
            tokenIn,
            amountIn
        );

        if (tokenIn == ETH) {
            IWETH9 weth = IWETH9(wrappedNativeAddress);
            weth.deposit{ value: amountIn }();
        }
    }

    /// @dev Transfers {amountIn} of {tokenIn} from the user to the Sickle
    /// contract, charging the fees and converting the amount to WETH if
    /// necessary
    /// @param tokenIn Address of the token to transfer
    /// @param amountIn Amount of the token to transfer
    /// @param strategy Address of the caller strategy
    /// @param feeSelector Selector of the caller function
    function _sickle_transfer_token_from_user(
        address tokenIn,
        uint256 amountIn,
        address strategy,
        bytes4 feeSelector
    ) public payable onlyRegisteredSickle {
        _checkMsgValue(amountIn, tokenIn == ETH);

        _transfer_token_from_user(tokenIn, amountIn, strategy, feeSelector);
    }

    /// @dev Transfers {amountIn} of {tokenIn} from the user to the Sickle
    /// contract, charging the fees and converting the amount to WETH if
    /// necessary
    /// @param tokensIn Addresses of the tokens to transfer
    /// @param amountsIn Amounts of the tokens to transfer
    /// @param strategy Address of the caller strategy
    /// @param feeSelector Selector of the caller function
    function _sickle_transfer_tokens_from_user(
        address[] memory tokensIn,
        uint256[] memory amountsIn,
        address strategy,
        bytes4 feeSelector
    ) external payable onlyRegisteredSickle {
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
            _transfer_token_from_user(
                tokensIn[i], amountsIn[i], strategy, feeSelector
            );
        }

        if (!hasEth) {
            // Revert if ETH was sent but not used
            _checkMsgValue(0, false);
        }
    }
}
