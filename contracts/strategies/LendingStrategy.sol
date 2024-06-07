// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../Sickle.sol";
import "../interfaces/IFarmConnector.sol";

import "./lending/FlashloanCallback.sol";

contract LendingStrategy is FlashloanCallback {
    error SwapPathNotSupported(); // 0x6b46d10f
    error InputArgumentsMismatch(); // 0xe3814450

    struct DepositParams {
        address tokenIn;
        uint256 amountIn;
        ZapModule.ZapInData zapData;
    }

    struct WithdrawParams {
        address tokenOut;
        ZapModule.ZapOutData zapData;
    }

    struct CompoundParams {
        address stakingContract;
        bytes extraData;
        ZapModule.ZapInData zapData;
    }

    constructor(
        SickleFactory factory,
        FeesLib feesLib,
        address wrappedNativeAddress,
        ConnectorRegistry connectorRegistry,
        FlashloanStrategy flashloanStrategy
    )
        FlashloanCallback(
            factory,
            feesLib,
            wrappedNativeAddress,
            connectorRegistry,
            flashloanStrategy
        )
    { }

    /// FLASHLOAN FUNCTIONS ///

    /// @notice Deposit using a zap
    /// Deposit asset X, swap for asset A
    /// Flashloan asset A, or flashloan asset Z and swap for asset A
    /// Supply asset A, borrow asset A + fees, repay flashloan
    function deposit(
        DepositParams calldata depositParams,
        IncreaseParams calldata increaseParams,
        FlashloanParams calldata flashloanParams,
        address[] memory sweepTokens,
        address approved,
        bytes32 referralCode
    ) public payable flashloanParamCheck(flashloanParams) {
        Sickle sickle = Sickle(
            payable(factory.getOrDeploy(msg.sender, approved, referralCode))
        );

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = address(this);
        data[0] = abi.encodeCall(
            this._sickle_transfer_token_from_user,
            (
                depositParams.tokenIn,
                depositParams.amountIn,
                address(this),
                LendingStrategyFees.Deposit
            )
        );

        targets[1] = address(this);
        data[1] =
            abi.encodeCall(ZapModule._sickle_zap_in, (depositParams.zapData));

        sickle.multicall{ value: msg.value }(targets, data);

        flashloan_deposit(address(sickle), increaseParams, flashloanParams);

        targets = new address[](1);
        data = new bytes[](1);

        targets[0] = address(this);
        data[0] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }

    /// @notice Repay asset A loan with flashloan, withdraw collateral asset A
    function withdraw(
        DecreaseParams calldata decreaseParams,
        FlashloanParams calldata flashloanParams,
        WithdrawParams calldata withdrawParams,
        address[] memory sweepTokens
    ) public {
        Sickle sickle = getSickle(msg.sender);

        flashloan_withdraw(address(sickle), decreaseParams, flashloanParams);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        targets[0] = address(this);
        data[0] =
            abi.encodeCall(ZapModule._sickle_zap_out, (withdrawParams.zapData));

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fee,
            (
                address(this),
                LendingStrategyFees.Withdraw,
                withdrawParams.tokenOut
            )
        );

        targets[2] = address(this);
        data[2] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }

    /// @notice Claim accrued rewards, sell for loan token and leverage with
    /// flashloan
    function compound(
        CompoundParams calldata compoundParams,
        IncreaseParams calldata increaseParams,
        FlashloanParams calldata flashloanParams,
        address[] memory sweepTokens
    ) public {
        Sickle sickle = getSickle(msg.sender);

        // delegatecall callback function
        address[] memory targets = new address[](3);
        targets[0] =
            connectorRegistry.connectorOf(compoundParams.stakingContract);
        targets[1] = address(this);
        targets[2] = address(this);

        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (compoundParams.stakingContract, compoundParams.extraData)
        );
        data[1] =
            abi.encodeCall(ZapModule._sickle_zap_in, (compoundParams.zapData));
        address flashloanToken = flashloanParams.flashloanAssets[0]
            == address(0)
            ? flashloanParams.flashloanAssets[1]
            : flashloanParams.flashloanAssets[0];
        data[2] = abi.encodeCall(
            this._sickle_charge_fee,
            (address(this), LendingStrategyFees.Compound, flashloanToken)
        );

        sickle.multicall(targets, data);

        flashloan_deposit(address(sickle), increaseParams, flashloanParams);

        targets = new address[](1);
        data = new bytes[](1);

        targets[0] = address(this);
        data[0] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }
}
