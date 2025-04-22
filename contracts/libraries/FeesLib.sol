// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { WETH } from "solmate/tokens/WETH.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Sickle } from "contracts/Sickle.sol";
import { SickleRegistry } from "contracts/SickleRegistry.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import { BPS_BASIS } from "contracts/base/Constants.sol";

contract FeesLib is IFeesLib {
    /// @notice Fees library version
    uint256 public constant VERSION = 1;

    /// @notice Sickle registry address
    SickleRegistry public immutable registry;

    /// @notice WETH9 token address
    WETH public immutable weth;

    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant UNISWAP_ETH =
        0x0000000000000000000000000000000000000000;

    constructor(SickleRegistry registry_, WETH weth_) {
        registry = registry_;
        weth = weth_;
    }

    /**
     * @notice Strategy contract charges fee to user depending on the type of
     * action and sends funds to the collector address
     * @param strategy Address of the strategy contract
     * @param feeDescriptor Descriptor of the fee to be charged
     * @param feeToken Address of the token from which an amount will be
     * @param feeBasis Amount to be charged (zero if on full amount)
     * charged (zero address if native token)
     */
    function chargeFee(
        address strategy,
        bytes4 feeDescriptor,
        address feeToken,
        uint256 feeBasis
    ) public payable returns (uint256 remainder) {
        uint256 fee = registry.feeRegistry(
            keccak256(abi.encodePacked(strategy, feeDescriptor))
        );

        if (feeBasis == 0) {
            if (feeToken == ETH || feeToken == UNISWAP_ETH) {
                uint256 wethBalance = weth.balanceOf(address(this));
                if (wethBalance > 0) {
                    weth.withdraw(wethBalance);
                }
                feeBasis = address(this).balance;
            } else {
                feeBasis = IERC20(feeToken).balanceOf(address(this));
            }
        }

        uint256 amountToCharge = feeBasis * fee / BPS_BASIS;

        if (amountToCharge == 0) {
            return feeBasis;
        }

        if (feeToken == ETH || feeToken == UNISWAP_ETH) {
            SafeTransferLib.safeTransferETH(
                registry.collector(), amountToCharge
            );
        } else {
            SafeTransferLib.safeTransfer(
                feeToken, registry.collector(), amountToCharge
            );
        }

        emit FeeCharged(strategy, feeDescriptor, amountToCharge, feeToken);
        return feeBasis - amountToCharge;
    }

    function chargeFees(
        address strategy,
        bytes4 feeDescriptor,
        address[] memory feeTokens
    ) external payable {
        for (uint256 i = 0; i < feeTokens.length;) {
            chargeFee(strategy, feeDescriptor, feeTokens[i], 0);
            unchecked {
                i++;
            }
        }
    }

    function getBalance(
        Sickle sickle,
        address token
    ) public view returns (uint256) {
        if (token == ETH) {
            return weth.balanceOf(address(sickle));
        } else if (token == UNISWAP_ETH) {
            return address(sickle).balance;
        }
        return IERC20(token).balanceOf(address(sickle));
    }
}
