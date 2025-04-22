// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBGT {
    function redeem(address receiver, uint256 amount) external;
    function renounceOwnership() external;
    function setActivateBoostDelay(
        uint32 _activateBoostDelay
    ) external;
    function setBgtTermsAndConditions(
        string calldata _bgtTermsAndConditions
    ) external;
    function setDropBoostDelay(
        uint32 _dropBoostDelay
    ) external;
    function setMinter(
        address _minter
    ) external;
    function setStaker(
        address _staker
    ) external;
    function staker() external view returns (address);
    function symbol() external pure returns (string memory);
    function totalBoosts() external view returns (uint128);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
    function transferOwnership(
        address newOwner
    ) external;
    function unboostedBalanceOf(
        address account
    ) external view returns (uint256);
    function whitelistSender(address sender, bool approved) external;
}
