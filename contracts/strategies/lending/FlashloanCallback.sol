// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import "../../interfaces/ILendingConnector.sol";
import "../../interfaces/IFlashloanCallback.sol";
import "../modules/ZapModule.sol";
import "../FlashloanStrategy.sol";
import "./FlashloanInitiator.sol";

abstract contract FlashloanCallback is
    IFlashloanCallback,
    FlashloanInitiator,
    ZapModule
{
    struct FlashloanedAsset {
        address contractAddress;
        uint256 flashloanedAmount;
        uint256 premium;
    }

    address public immutable lendingStrategyAddress;

    constructor(
        SickleFactory factory,
        FeesLib feesLib,
        address wrappedNativeAddress,
        ConnectorRegistry connectorRegistry,
        FlashloanStrategy flashloanStrategy
    )
        FlashloanInitiator(flashloanStrategy)
        ZapModule(factory, feesLib, wrappedNativeAddress, connectorRegistry)
    {
        lendingStrategyAddress = address(this);
    }

    /// Flashloan callbacks ///

    /// @notice Callback function for flashloan_deposit()
    /// Optionally swaps the flashloan for the collateral asset,
    /// supplies the loaned amount,
    /// borrows from the debt market (plus fee) to repay the flashloan
    function flashloan_deposit_callback(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        bytes calldata extraData
    ) external onlyRegisteredSickle {
        if (msg.sender != address(flashloanStrategy)) {
            revert FlashloanStrategy.NotFlashloanStrategy();
        }

        Sickle sickle = Sickle(payable(address(this)));

        // handling uniV2/uniV3 flashloans where token1 in the Pair is the one
        // being borrowed and flashloaned asset appears at index 1 of function
        // parameters
        uint256 assetIndex = amounts[0] > 0 ? 0 : 1;

        FlashloanedAsset memory flashloanedAsset = FlashloanedAsset({
            contractAddress: assets[assetIndex],
            flashloanedAmount: amounts[assetIndex],
            premium: premiums[assetIndex]
        });

        IncreaseParams memory increaseParams =
            abi.decode(extraData, (IncreaseParams));

        charge_flashloan_fees(flashloanedAsset);

        if (increaseParams.optionalSwap.router != address(0)) {
            _swap(increaseParams.optionalSwap);
        }

        // updating sickle balance after fees and swap
        uint256 supplyAmount = get_balance(sickle, increaseParams.token);

        _delegateTo(
            connectorRegistry.connectorOf(increaseParams.market),
            abi.encodeCall(
                ILendingConnector.mint,
                (increaseParams.market, supplyAmount, increaseParams.extraData)
            )
        );

        _delegateTo(
            connectorRegistry.connectorOf(increaseParams.market),
            abi.encodeCall(
                ILendingConnector.borrow,
                (
                    increaseParams.market,
                    flashloanedAsset.flashloanedAmount
                        + flashloanedAsset.premium,
                    increaseParams.extraData
                )
            )
        );

        // send borrowed amounts to FlashloanStrategy contract for repayment
        SafeTransferLib.safeTransfer(
            flashloanedAsset.contractAddress,
            address(flashloanStrategy),
            flashloanedAsset.flashloanedAmount + flashloanedAsset.premium
        );
    }

    /// @notice Callback function for flashloan_withdraw()
    /// Repays the loaned amount, withdraws collateral and repays the flashloan
    function flashloan_withdraw_callback(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        bytes calldata extraData
    ) public onlyRegisteredSickle {
        if (msg.sender != address(flashloanStrategy)) {
            revert FlashloanStrategy.NotFlashloanStrategy();
        }

        DecreaseParams memory decreaseParams =
            abi.decode(extraData, (DecreaseParams));

        uint256 assetIndex = amounts[0] > 0 ? 0 : 1;

        FlashloanedAsset memory flashloanedAsset = FlashloanedAsset({
            contractAddress: assets[assetIndex],
            flashloanedAmount: amounts[assetIndex],
            premium: premiums[assetIndex]
        });

        charge_flashloan_fees(flashloanedAsset);

        _delegateTo(
            connectorRegistry.connectorOf(decreaseParams.market),
            abi.encodeCall(
                ILendingConnector.repay,
                (
                    decreaseParams.market,
                    decreaseParams.repayAmount,
                    decreaseParams.extraData
                )
            )
        );

        if (decreaseParams.redeemAmount > 0) {
            _delegateTo(
                connectorRegistry.connectorOf(decreaseParams.market),
                abi.encodeCall(
                    ILendingConnector.redeem,
                    (
                        decreaseParams.market,
                        decreaseParams.redeemAmount,
                        decreaseParams.extraData
                    )
                )
            );
        }

        if (decreaseParams.optionalSwap.router != address(0)) {
            _swap(decreaseParams.optionalSwap);
        }

        // send borrowed amounts to FlashloanStrategy contract for repayment
        SafeTransferLib.safeTransfer(
            flashloanedAsset.contractAddress,
            address(flashloanStrategy),
            flashloanedAsset.flashloanedAmount + flashloanedAsset.premium
        );
    }

    function charge_flashloan_fees(FlashloanedAsset memory params) internal {
        _charge_fees(
            keccak256(
                abi.encodePacked(
                    lendingStrategyAddress, LendingStrategyFees.Flashloan
                )
            ),
            params.contractAddress,
            params.flashloanedAmount
        );
    }

    function get_balance(
        Sickle sickle,
        address token
    ) private view returns (uint256) {
        if (token == ETH) {
            return IERC20(wrappedNativeAddress).balanceOf(address(sickle));
        }
        return IERC20(token).balanceOf(address(sickle));
    }
}
