// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../../libraries/FeesLib.sol";
import { IWETH9 } from "../../interfaces/external/IWETH.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./DelegateModule.sol";

address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

contract FeesModule is DelegateModule {
    FeesLib public immutable feesLib;
    address public immutable wrappedNativeAddress;

    constructor(FeesLib feesLib_, address wrappedNativeAddress_) {
        feesLib = feesLib_;
        wrappedNativeAddress = wrappedNativeAddress_;
    }

    /// INTERNALS ///

    function _charge_fees(
        bytes32 feeHash,
        address tokenToCharge,
        uint256 baseAmount
    ) internal returns (uint256 remainingAmount) {
        (remainingAmount) = abi.decode(
            _delegateTo(
                address(feesLib),
                abi.encodeCall(
                    FeesLib.chargeFees, (feeHash, tokenToCharge, baseAmount)
                )
            ),
            (uint256)
        );
    }

    function _sickle_charge_fee(
        address strategy,
        bytes4 feeDescriptor,
        address feeToken
    ) public {
        IWETH9 weth = IWETH9(wrappedNativeAddress);
        uint256 feeBasis;
        if (feeToken == ETH) {
            weth.withdraw(weth.balanceOf(address(this)));
            feeBasis = address(this).balance;
        } else {
            feeBasis = IERC20(feeToken).balanceOf(address(this));
        }
        _charge_fees(
            keccak256(abi.encodePacked(strategy, feeDescriptor)),
            feeToken,
            feeBasis
        );
    }

    function _sickle_charge_fees(
        address strategy,
        bytes4 feeDescriptor,
        address[] memory feeTokens
    ) external {
        for (uint256 i = 0; i < feeTokens.length;) {
            _sickle_charge_fee(strategy, feeDescriptor, feeTokens[i]);
            unchecked {
                i++;
            }
        }
    }

    function _sickle_charge_transaction_cost(
        address recipient,
        address wrappedNative,
        uint256 amountToCharge
    ) external {
        _delegateTo(
            address(feesLib),
            abi.encodeCall(
                FeesLib.chargeTransactionCost,
                (recipient, wrappedNative, amountToCharge)
            )
        );
    }
}
