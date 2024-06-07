// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import "./LendingStructs.sol";
import "../../interfaces/IFlashloanCallback.sol";
import "../FlashloanStrategy.sol";

abstract contract FlashloanInitiator is LendingStructs {
    modifier flashloanParamCheck(FlashloanParams calldata flashloanParams) {
        if (
            flashloanParams.flashloanAssets.length
                != flashloanParams.flashloanAmounts.length
        ) {
            revert SickleRegistry.ArrayLengthMismatch();
        }
        _;
    }

    FlashloanStrategy public immutable flashloanStrategy;

    constructor(FlashloanStrategy flashloanStrategy_) {
        flashloanStrategy = flashloanStrategy_;
    }

    /// Internal functions ///

    function flashloan_deposit(
        address sickleAddress,
        IncreaseParams calldata increaseParams,
        FlashloanParams calldata flashloanParams
    ) internal {
        uint256[] memory premiums = flashloanStrategy.calculatePremiums(
            flashloanParams.flashloanProvider, flashloanParams.flashloanAmounts
        );

        bytes memory callback = abi.encodeCall(
            IFlashloanCallback.flashloan_deposit_callback,
            (
                flashloanParams.flashloanAssets,
                flashloanParams.flashloanAmounts,
                premiums,
                abi.encode(increaseParams)
            )
        );
        flashloanStrategy.initiateFlashloan(
            sickleAddress,
            flashloanParams.flashloanProvider,
            flashloanParams.flashloanAssets,
            flashloanParams.flashloanAmounts,
            callback
        );
    }

    function flashloan_withdraw(
        address sickleAddress,
        DecreaseParams calldata decreaseParams,
        FlashloanParams calldata flashLoanParams
    ) internal {
        // calculate expected premiums on flashloan amount
        uint256[] memory premiums = flashloanStrategy.calculatePremiums(
            flashLoanParams.flashloanProvider, flashLoanParams.flashloanAmounts
        );

        bytes memory encoded = abi.encodeCall(
            IFlashloanCallback.flashloan_withdraw_callback,
            (
                flashLoanParams.flashloanAssets,
                flashLoanParams.flashloanAmounts,
                premiums,
                abi.encode(decreaseParams)
            )
        );

        flashloanStrategy.initiateFlashloan(
            sickleAddress,
            flashLoanParams.flashloanProvider,
            flashLoanParams.flashloanAssets,
            flashLoanParams.flashloanAmounts,
            encoded
        );
    }
}
