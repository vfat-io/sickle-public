// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { IRouterAllowlist } from "contracts/interfaces/IRouterAllowlist.sol";
import { IBridgeLib } from "contracts/interfaces/libraries/IBridgeLib.sol";

interface IWETH {
    function withdraw(uint256) external;
}

contract BridgeLib is IBridgeLib {
    IRouterAllowlist public immutable allowlist;
    address public immutable weth;

    /// @dev Stored at deploy time; used to enforce delegatecall-only access.
    address private immutable _self;

    constructor(IRouterAllowlist allowlist_, address weth_) {
        allowlist = allowlist_;
        weth = weth_;
        _self = address(this);
    }

    function bridge(
        address bridgeContract,
        bytes calldata bridgeCalldata,
        address token,
        uint256 amount
    ) external payable {
        if (amount == 0) revert ZeroBridgeAmount();

        // 0. Ensure we're running inside a Sickle via delegatecall
        if (address(this) == _self) {
            revert NotDelegatecall();
        }

        // 1. Validate bridge contract + selector against allowlist
        allowlist.requireAllowedBridge(bridgeContract);
        if (bridgeCalldata.length < 4) {
            revert BridgeFailed("calldata too short");
        }
        allowlist.requireAllowedSelector(
            bridgeContract, bytes4(bridgeCalldata[:4])
        );

        bool isNative = token == address(0);
        uint256 balanceBefore;

        if (isNative) {
            // 2a. Native ETH: unwrap WETH to ETH, record ETH balance
            //     less `msg.value`. The relay fee is forwarded as part of
            //     `callValue`; subtracting it from the snapshot means the
            //     post-call balance delta measures principal consumption
            //     only and an unconsumed relay-fee remainder cannot mask
            //     under-consumption of `amount`.
            IWETH(weth).withdraw(amount);
            balanceBefore = address(this).balance - msg.value;
        } else {
            // 2b. ERC20: approve bridge contract
            SafeTransferLib.safeApprove(token, bridgeContract, 0);
            SafeTransferLib.safeApprove(token, bridgeContract, amount);
            balanceBefore = IERC20(token).balanceOf(address(this));
        }

        // 3. Call bridge contract with pre-encoded calldata
        // For native ETH: forward exactly unwrapped amount + relay fee
        // For ERC20: forward only msg.value (relay fee)
        uint256 callValue = isNative ? amount + msg.value : msg.value;
        (bool success, bytes memory result) =
            bridgeContract.call{ value: callValue }(bridgeCalldata);
        if (!success) {
            if (result.length == 0) revert();
            assembly {
                revert(add(32, result), mload(result))
            }
        }

        // 4. Verify bridge consumed at least amount. For native, the
        //    `balanceBefore` subtraction above makes this assert that the
        //    bridge consumed the full `amount + msg.value` — bridges that
        //    refund any portion of the relay fee will revert here.
        uint256 balanceAfter = isNative
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
        if (balanceBefore - balanceAfter < amount) {
            revert BridgeDidNotConsumeTokens();
        }

        // 5. Revoke approval (ERC20 only)
        if (!isNative) {
            SafeTransferLib.safeApprove(token, bridgeContract, 0);
        }
    }
}
