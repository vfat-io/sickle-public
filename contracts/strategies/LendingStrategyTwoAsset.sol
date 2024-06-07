// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./lending/FlashloanInitiator.sol";
import "../interfaces/ILendingConnector.sol";
import "./modules/ZapModule.sol";

contract LendingStrategyTwoAsset is FlashloanInitiator, ZapModule {
    error SwapPathNotSupported(); // 0x6b46d10f
    error InputArgumentsMismatch(); // 0xe3814450

    struct SupplyParams {
        // The collateral asset
        address market;
        address token;
        uint256 amountIn; // Amount transferred from user
        bytes extraData;
    }

    struct RedeemParams {
        // The collateral asset
        address market;
        address token;
        uint256 amount;
        bytes extraData;
    }

    constructor(
        SickleFactory factory,
        FeesLib feesLib,
        address wrappedNativeAddress,
        ConnectorRegistry connectorRegistry,
        FlashloanStrategy flashloanStrategy
    )
        FlashloanInitiator(flashloanStrategy)
        ZapModule(factory, feesLib, wrappedNativeAddress, connectorRegistry)
    { }

    /// FLASHLOAN FUNCTIONS ///

    /// Two-asset functions (Supply asset A, Borrow+Leverage asset B) ///

    /// @notice Deposit collateral asset A, flash loan and leverage asset B
    function deposit_and_borrow(
        SupplyParams calldata collateralTokenParams,
        IncreaseParams calldata increaseParams,
        FlashloanParams calldata flashloanParams,
        address approved,
        bytes32 referralCode
    ) public payable {
        Sickle sickle = Sickle(
            payable(factory.getOrDeploy(msg.sender, approved, referralCode))
        );
        address[] memory targets = new address[](2);
        targets[0] = address(this);
        targets[1] = connectorRegistry.connectorOf(collateralTokenParams.market);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(
            this._sickle_transfer_token_from_user,
            (
                collateralTokenParams.token,
                collateralTokenParams.amountIn,
                address(this),
                LendingStrategyFees.Deposit
            )
        );
        data[1] = abi.encodeCall(
            ILendingConnector.mint,
            (
                collateralTokenParams.market,
                collateralTokenParams.amountIn,
                collateralTokenParams.extraData
            )
        );

        sickle.multicall{ value: msg.value }(targets, data);

        flashloan_deposit(address(sickle), increaseParams, flashloanParams);
    }

    /// @notice Repay asset B loan with flashloan, withdraw collateral asset A
    function repay_and_withdraw(
        SwapData calldata interestSwapData,
        DecreaseParams calldata decreaseParams,
        FlashloanParams calldata flashloanParams,
        RedeemParams calldata collateralTokenParams,
        address[] memory sweepTokens
    ) public {
        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = connectorRegistry.connectorOf(collateralTokenParams.market);
        data[0] = abi.encodeCall(
            ILendingConnector.redeemUnderlying,
            (
                collateralTokenParams.market,
                interestSwapData.amountIn,
                collateralTokenParams.extraData
            )
        );

        targets[1] = address(this);
        data[1] = abi.encodeCall(SwapModule._sickle_swap, (interestSwapData));

        sickle.multicall(targets, data);

        flashloan_withdraw(address(sickle), decreaseParams, flashloanParams);

        targets[0] = connectorRegistry.connectorOf(collateralTokenParams.market);
        data[0] = abi.encodeCall(
            ILendingConnector.redeem,
            (
                collateralTokenParams.market,
                collateralTokenParams.amount,
                collateralTokenParams.extraData
            )
        );

        targets[1] = address(this);
        data[1] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }
}
