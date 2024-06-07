// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { WETH } from "solmate/tokens/WETH.sol";

import "../SickleRegistry.sol";

contract FeesLib {
    event FeeCharged(bytes32 feesHash, uint256 amount, address token);
    event TransactionCostCharged(address recipient, uint256 amount);

    /// @notice Fees library version
    uint256 public constant VERSION = 1;

    /// @notice Sickle registry address
    SickleRegistry public immutable registry;

    constructor(SickleRegistry registry_) {
        registry = registry_;
    }

    /**
     * @notice Strategy contract charges fee to user depending on the type of
     * action and sends funds to the collector address
     * @param feeHash Fee hash (address of the strategy and function selector)
     * @param tokenToCharge Address of the token from which an amount will be
     * charged (zero address if native token)
     * @param baseAmount Amount of the transaction serving as a base for fee
     * calculation
     */
    function chargeFees(
        bytes32 feeHash,
        address tokenToCharge,
        uint256 baseAmount
    ) public payable returns (uint256) {
        uint256 fee = registry.feeRegistry(feeHash);

        if (fee == 0) {
            return baseAmount;
        }

        uint256 amountToCharge = baseAmount * fee / 10_000;

        if (
            tokenToCharge == address(0)
                || tokenToCharge == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
        ) {
            SafeTransferLib.safeTransferETH(
                registry.collector(), amountToCharge
            );
        } else {
            SafeTransferLib.safeTransfer(
                tokenToCharge, registry.collector(), amountToCharge
            );
        }

        emit FeeCharged(feeHash, amountToCharge, tokenToCharge);
        return baseAmount - amountToCharge;
    }

    function chargeTransactionCost(
        address recipient,
        address wrappedNative,
        uint256 amountToCharge
    ) public payable {
        WETH(payable(wrappedNative)).withdraw(amountToCharge);
        SafeTransferLib.safeTransferETH(recipient, amountToCharge);
        emit TransactionCostCharged(recipient, amountToCharge);
    }
}
