// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICurveGauge {
    struct RewardData {
        address distributor;
        uint256 period_finish;
        uint256 rate;
        uint256 last_update;
        uint256 integral;
    }

    // Events
    event Deposit(address indexed provider, uint256 value);
    event Withdraw(address indexed provider, uint256 value);
    event UpdateLiquidityLimit(
        address indexed user,
        uint256 original_balance,
        uint256 original_supply,
        uint256 working_balance,
        uint256 working_supply
    );
    event SetGaugeManager(address _gauge_manager);
    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event Approval(
        address indexed _owner, address indexed _spender, uint256 _value
    );

    // Initialize function
    function initialize(
        address _lp_token,
        address _root,
        address _manager
    ) external;

    // Deposit functions
    function deposit(
        uint256 _value
    ) external;
    function deposit(uint256 _value, address _addr) external;
    function deposit(
        uint256 _value,
        address _addr,
        bool _claim_rewards
    ) external;

    // Withdraw functions
    function withdraw(
        uint256 _value
    ) external;
    function withdraw(uint256 _value, bool _claim_rewards) external;
    function withdraw(
        uint256 _value,
        bool _claim_rewards,
        address _receiver
    ) external;

    // Claim rewards functions
    function claim_rewards() external;
    function claim_rewards(
        address _addr
    ) external;
    function claim_rewards(address _addr, address _receiver) external;

    // ERC20 functions
    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) external returns (bool);
    function transfer(address _to, uint256 _value) external returns (bool);
    function approve(
        address _spender,
        uint256 _value
    ) external returns (bool);
    function permit(
        address _owner,
        address _spender,
        uint256 _value,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (bool);
    function increaseAllowance(
        address _spender,
        uint256 _added_value
    ) external returns (bool);
    function decreaseAllowance(
        address _spender,
        uint256 _subtracted_value
    ) external returns (bool);

    // Admin functions
    function user_checkpoint(
        address addr
    ) external returns (bool);
    function set_rewards_receiver(
        address _receiver
    ) external;
    function set_gauge_manager(
        address _gauge_manager
    ) external;
    function set_manager(
        address _gauge_manager
    ) external;
    function deposit_reward_token(
        address _reward_token,
        uint256 _amount
    ) external;
    function deposit_reward_token(
        address _reward_token,
        uint256 _amount,
        uint256 _epoch
    ) external;
    function recover_remaining(
        address _reward_token
    ) external;
    function add_reward(address _reward_token, address _distributor) external;
    function set_reward_distributor(
        address _reward_token,
        address _distributor
    ) external;
    function set_killed(
        bool _is_killed
    ) external;
    function set_root_gauge(
        address _root
    ) external;
    function update_voting_escrow() external;

    // View functions
    function claimed_reward(
        address _addr,
        address _token
    ) external view returns (uint256);
    function claimable_reward(
        address _user,
        address _reward_token
    ) external view returns (uint256);
    function claimable_tokens(
        address addr
    ) external returns (uint256);
    function integrate_checkpoint() external view returns (uint256);
    function decimals() external view returns (uint256);
    function version() external view returns (string memory);
    function factory() external view returns (address);
    function voting_escrow() external view returns (address);
    function balanceOf(
        address arg0
    ) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function allowance(
        address arg0,
        address arg1
    ) external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(
        address arg0
    ) external view returns (uint256);
    function manager() external view returns (address);
    function lp_token() external view returns (address);
    function is_killed() external view returns (bool);
    function inflation_rate(
        uint256 arg0
    ) external view returns (uint256);
    function reward_count() external view returns (uint256);
    function reward_data(
        address arg0
    ) external view returns (RewardData memory);
    function reward_remaining(
        address arg0
    ) external view returns (uint256);
    function rewards_receiver(
        address arg0
    ) external view returns (address);
    function reward_integral_for(
        address arg0,
        address arg1
    ) external view returns (uint256);
    function working_balances(
        address arg0
    ) external view returns (uint256);
    function working_supply() external view returns (uint256);
    function integrate_inv_supply_of(
        address arg0
    ) external view returns (uint256);
    function integrate_checkpoint_of(
        address arg0
    ) external view returns (uint256);
    function integrate_fraction(
        address arg0
    ) external view returns (uint256);
    function period() external view returns (int128);
    function reward_tokens(
        uint256 arg0
    ) external view returns (address);
    function period_timestamp(
        int128 arg0
    ) external view returns (uint256);
    function integrate_inv_supply(
        int128 arg0
    ) external view returns (uint256);
    function root_gauge() external view returns (address);
}
