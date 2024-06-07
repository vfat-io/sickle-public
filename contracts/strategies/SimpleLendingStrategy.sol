// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./lending/FlashloanInitiator.sol";
import "./modules/TransferModule.sol";

contract SimpleLendingStrategy is FlashloanInitiator, TransferModule {
    constructor(
        SickleFactory factory,
        FeesLib feesLib,
        address wrappedNativeAddress,
        FlashloanStrategy flashloanStrategy
    )
        FlashloanInitiator(flashloanStrategy)
        TransferModule(factory, feesLib, wrappedNativeAddress)
    { }

    /// FLASHLOAN FUNCTIONS ///

    /// @notice  Deposit and Borrow same asset
    /// Flashloan asset A, supply wallet funds + flashloan,
    /// borrow and repay flashloan
    function deposit(
        IncreaseParams calldata increaseParams,
        FlashloanParams calldata flashloanParams,
        address approved,
        bytes32 referralCode
    ) public payable flashloanParamCheck(flashloanParams) {
        Sickle sickle = Sickle(
            payable(factory.getOrDeploy(msg.sender, approved, referralCode))
        );

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(this);
        data[0] = abi.encodeCall(
            this._sickle_transfer_token_from_user,
            (
                increaseParams.token,
                increaseParams.amountIn,
                address(this),
                bytes4(0)
            )
        );

        sickle.multicall{ value: msg.value }(targets, data);

        flashloan_deposit(address(sickle), increaseParams, flashloanParams);
    }

    /// @notice Increase leverage (same asset)
    /// Flashloan asset A, supply flashloan, borrow and repay flashloan
    function increaseLeverage(
        IncreaseParams calldata increaseParams,
        FlashloanParams calldata flashloanParams
    ) public flashloanParamCheck(flashloanParams) {
        Sickle sickle = getSickle(msg.sender);

        flashloan_deposit(address(sickle), increaseParams, flashloanParams);
    }

    /// @notice Repay asset B loan with flashloan, withdraw collateral asset A
    function withdraw(
        DecreaseParams calldata decreaseParams,
        FlashloanParams calldata flashloanParams
    ) public flashloanParamCheck(flashloanParams) {
        Sickle sickle = getSickle(msg.sender);

        flashloan_withdraw(address(sickle), decreaseParams, flashloanParams);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(this);
        data[0] = abi.encodeCall(
            this._sickle_transfer_token_to_user, decreaseParams.token
        );

        sickle.multicall(targets, data);
    }

    /// @notice Decrease leverage by repaying asset B loan with flashloan
    function decreaseLeverage(
        DecreaseParams calldata decreaseParams,
        FlashloanParams calldata flashloanParams
    ) public flashloanParamCheck(flashloanParams) {
        Sickle sickle = getSickle(msg.sender);

        flashloan_withdraw(address(sickle), decreaseParams, flashloanParams);
    }
}
