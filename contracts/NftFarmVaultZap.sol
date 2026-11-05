// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { SwapStep } from "contracts/dex/SwapTypes.sol";

interface INftFarmVaultDeposit {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function deposit(
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint256 minShares,
        address receiver
    ) external returns (uint256 shares);
}

interface IVaultZapSwapRouter {
    function swap(
        SwapStep[] calldata steps,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
}

contract NftFarmVaultZap is ReentrancyGuard {
    using SafeTransferLib for address;

    struct ZapSwap {
        SwapStep[] steps;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    IVaultZapSwapRouter public immutable swapRouter;

    error Expired();
    error InvalidAmount();
    error InvalidConfig();

    event ZapDeposited(
        address indexed caller,
        address indexed vault,
        address indexed receiver,
        address tokenIn,
        uint256 amountIn,
        uint256 shares
    );

    constructor(
        IVaultZapSwapRouter swapRouter_
    ) {
        if (address(swapRouter_) == address(0)) revert InvalidConfig();
        swapRouter = swapRouter_;
    }

    function depositWithZap(
        INftFarmVaultDeposit vault,
        address tokenIn,
        uint256 amountIn,
        ZapSwap calldata swap_,
        uint256 minShares,
        address receiver,
        uint256 deadline
    ) external nonReentrant returns (uint256 shares) {
        if (block.timestamp > deadline) revert Expired();
        if (
            address(vault) == address(0) || tokenIn == address(0)
                || receiver == address(0)
        ) {
            revert InvalidConfig();
        }
        if (amountIn == 0) revert InvalidAmount();

        address token0 = vault.token0();
        address token1 = vault.token1();
        address otherToken;
        if (tokenIn == token0) {
            otherToken = token1;
        } else if (tokenIn == token1) {
            otherToken = token0;
        } else {
            revert InvalidConfig();
        }

        _pullExact(tokenIn, msg.sender, amountIn);
        _executeSwap(tokenIn, otherToken, swap_, deadline);

        shares = _depositToVault(vault, token0, token1, minShares, receiver);

        _refund(tokenIn, msg.sender);
        _refund(token0, msg.sender);
        _refund(token1, msg.sender);

        emit ZapDeposited(
            msg.sender, address(vault), receiver, tokenIn, amountIn, shares
        );
    }

    function _depositToVault(
        INftFarmVaultDeposit vault,
        address token0,
        address token1,
        uint256 minShares,
        address receiver
    ) internal returns (uint256 shares) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        if (balance0 == 0 || balance1 == 0) revert InvalidAmount();

        token0.safeApprove(address(vault), 0);
        token0.safeApprove(address(vault), balance0);
        token1.safeApprove(address(vault), 0);
        token1.safeApprove(address(vault), balance1);

        shares = vault.deposit(balance0, balance1, minShares, receiver);

        token0.safeApprove(address(vault), 0);
        token1.safeApprove(address(vault), 0);
    }

    function _executeSwap(
        address tokenIn,
        address tokenOut,
        ZapSwap calldata swap_,
        uint256 deadline
    ) internal {
        uint256 length = swap_.steps.length;
        if (length == 0) revert InvalidConfig();
        if (
            swap_.steps[0].tokenIn != tokenIn
                || swap_.steps[length - 1].tokenOut != tokenOut
        ) revert InvalidConfig();

        uint256 amountIn = swap_.amountIn;
        if (amountIn == 0) {
            amountIn = IERC20(tokenIn).balanceOf(address(this));
        }
        if (amountIn == 0) revert InvalidAmount();

        address router = address(swapRouter);
        tokenIn.safeApprove(router, 0);
        tokenIn.safeApprove(router, amountIn);
        swapRouter.swap(
            swap_.steps, amountIn, swap_.minAmountOut, address(this), deadline
        );
        tokenIn.safeApprove(router, 0);
    }

    function _pullExact(
        address token,
        address from,
        uint256 amount
    ) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - balanceBefore < amount) {
            revert InvalidAmount();
        }
    }

    function _refund(
        address token,
        address receiver
    ) internal {
        if (token == address(0)) return;
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) token.safeTransfer(receiver, balance);
    }
}
