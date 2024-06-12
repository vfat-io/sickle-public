// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICurveDepositToken {
    function PRISMA() external view returns (IERC20);

    function CRV() external view returns (IERC20);

    function gauge() external view returns (address);

    function lpToken() external view returns (IERC20);

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function symbol() external view returns (string memory);

    function name() external view returns (string memory);

    function decimals() external view returns (uint256);

    function emissionId() external view returns (uint256);

    function deposit(
        address receiver,
        uint256 amount
    ) external returns (bool);

    function withdraw(
        address receiver,
        uint256 amount
    ) external returns (bool);

    function claimReward(address receiver)
        external
        returns (uint256 prismaAmount, uint256 crvAmount);

    function claimableReward(address receiver)
        external
        returns (uint256 prismaAmount, uint256 crvAmount);
}

interface IConvexDepositToken {
    function claimReward(address receiver)
        external
        returns (uint256 prismaAmount, uint256 crvAmount, uint256 cvxAmount);

    function claimableReward(address receiver)
        external
        returns (uint256 prismaAmount, uint256 crvAmount, uint256 cvxAmount);
}

interface IPrismaLocker {
    function withdrawWithPenalty(uint256 amountToWithdraw)
        external
        returns (uint256);

    function getWithdrawWithPenaltyAmounts(
        address user,
        uint256 amountToWithdraw
    )
        external
        view
        returns (uint256 amountWithdrawn, uint256 penaltyAmountPaid);
}

contract PrismaConnector is IFarmConnector {
    IPrismaLocker public immutable locker;

    constructor(IPrismaLocker _locker) {
        locker = _locker;
    }

    function deposit(
        address target,
        address token,
        bytes memory // extraData
    ) external payable override {
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).approve(target, amount);
        ICurveDepositToken(target).deposit(address(this), amount);
    }

    function withdraw(
        address target,
        uint256 amount,
        bytes memory // extraData
    ) external override {
        ICurveDepositToken(target).withdraw(address(this), amount);
    }

    function claim(
        address target,
        bytes memory // extraData
    ) external override {
        (uint256 prismaAmount,) =
            ICurveDepositToken(target).claimReward(address(this));
        if (prismaAmount > 1 ether) {
            locker.withdrawWithPenalty(type(uint256).max);
        }
    }
}
