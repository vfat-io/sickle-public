// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { Admin } from "contracts/base/Admin.sol";
import { BPS_BASIS } from "contracts/base/Constants.sol";
import { Automation } from "contracts/Automation.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { Sickle } from "contracts/Sickle.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { NftFarmStrategy } from "contracts/strategies/NftFarmStrategy.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { INftFarmVault } from "contracts/interfaces/INftFarmVault.sol";
import {
    INftLiquidityAmountsResolver
} from "contracts/interfaces/INftLiquidityAmountsResolver.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import {
    INftTokenIdResolver
} from "contracts/interfaces/INftTokenIdResolver.sol";
import {
    INftDepositCallback
} from "contracts/interfaces/INftDepositCallback.sol";
import {
    INftRebalanceCallback
} from "contracts/interfaces/INftRebalanceCallback.sol";
import {
    IUniswapV3Pool
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { ICLPool } from "contracts/interfaces/external/aerodrome/ICLPool.sol";
import {
    INftSettingsRegistry
} from "contracts/interfaces/INftSettingsRegistry.sol";
import {
    StakeSettingsRegistry,
    StakeConfig
} from "contracts/StakeSettingsRegistry.sol";
import { NftVaultTwapLib } from "contracts/libraries/NftVaultTwapLib.sol";
import { AutomationPermissions } from
    "contracts/libraries/AutomationPermissions.sol";
import {
    NftPosition,
    NftIncrease
} from "contracts/structs/NftFarmStrategyStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {
    NftKey,
    NftSettings
} from "contracts/structs/NftSettingsStructs.sol";
import {
    NftPoolKey,
    NftPoolInfo,
    NftAddLiquidity
} from "contracts/structs/NftLiquidityStructs.sol";
import { NftVaultCallLib } from "contracts/libraries/NftVaultCallLib.sol";

abstract contract NftFarmVault is Admin, ReentrancyGuard, INftFarmVault {
    using SafeTransferLib for address;

    struct VaultInit {
        SickleFactory factory;
        NftFarmStrategy nftFarmStrategy;
        Automation automation;
        ConnectorRegistry connectorRegistry;
        INftTokenIdResolver tokenIdResolver;
        INftLiquidityAmountsResolver liquidityAmountsResolver;
        address nftManager;
        address pool;
        bytes32 poolId;
        uint32 twapWindow;
        uint24 maxTickDeviation;
        uint16 maxRebalanceLossBps;
        uint24 addLiquiditySlippageBps;
        bool inPlace;
        bytes addLiquidityExtraData;
        bytes removeLiquidityExtraData;
        bytes32 referralCode;
        // Deposit liquidity caps: the max pool liquidity allowed to remain
        // after a deposit, and the max receiver share-proportional liquidity.
        // 0 disables a cap. capInToken0 only selects the currentCapValue()
        // readout denomination and is fixed at deployment.
        uint256 depositCap;
        uint256 perUserDepositCap;
        bool capInToken0;
        address capRaiser;
        // When true (Aerodrome CL stake-mode vaults), deposit/redeem/harvest
        // become staked<->unstaked aware so the vault survives a
        // StakeStrategy flip. Non-stake-mode vaults (e.g. plain reward
        // farms where the NFT is never gauge-staked) leave this false and behave
        // exactly as before.
        bool stakeEnabled;
        // Typed per-position policy store for the stake-mode auto-flip (an
        // ISettingsModule). Only required (non-zero) when stakeEnabled;
        // setStakeConfig writes the position's StakeConfig here as the
        // Sickle owner.
        StakeSettingsRegistry stakeSettingsRegistry;
    }

    struct DepositCache {
        NftPoolInfo poolInfo;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidityBefore;
        uint256 currentAmount0;
        uint256 currentAmount1;
        uint256 vaultAmount0;
        uint256 vaultAmount1;
        uint256 amount0;
        uint256 amount1;
        uint256 liquidityDelta;
    }

    struct RedeemCache {
        uint256 supply;
        uint128 liquidityToRemove;
        uint128 amount0Max;
        uint128 amount1Max;
        uint256 balance0Before;
        uint256 balance1Before;
        bool fullWithdraw;
    }

    error InvalidConfig();
    error PositionNotSet();
    error PositionOutOfRange();
    error PriceMoved();
    error Slippage();
    error InvalidAmount();
    error InvalidToken();
    error NotAutomation();
    error InvalidSickle();
    error PositionAlreadySet();
    error RebalanceValueLoss();
    error DepositCapExceeded();
    error UserDepositCapExceeded();
    error NotCapRaiser();
    error CapNotLowered();
    error NotStakeEnabled();

    event CapChanged(uint256 depositCap, uint256 perUserDepositCap);

    event PositionSet(
        address indexed nft,
        uint256 indexed tokenId,
        address indexed stakingContract,
        uint256 poolIndex
    );
    event TokenRecovered(
        address indexed token, address indexed receiver, uint256 amount
    );
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(
        address indexed owner, address indexed spender, uint256 amount
    );

    Sickle public immutable sickle;
    NftFarmStrategy internal immutable nftFarmStrategy;
    Automation internal immutable automation;
    ConnectorRegistry internal immutable connectorRegistry;
    INftTokenIdResolver internal immutable tokenIdResolver;
    INftLiquidityAmountsResolver internal immutable liquidityAmountsResolver;
    address internal immutable nftManager;

    address public immutable token0;
    address public immutable token1;
    address internal immutable pool;
    bytes32 internal immutable poolId;
    uint24 internal immutable addLiquiditySlippageBps;
    bool internal immutable inPlace;
    bool internal immutable stakeEnabled;
    StakeSettingsRegistry internal immutable stakeSettingsRegistry;

    /// @dev Upper bound on maxTickDeviation so admin config cannot effectively
    /// disable the deposit TWAP guard. ~49% price band — far above any sane
    /// per-pool setting, but finite (vs the 887272 tick space).
    uint24 internal constant MAX_TICK_DEVIATION_LIMIT = 4000;

    uint32 internal twapWindow;
    uint24 internal maxTickDeviation;
    uint16 internal maxRebalanceLossBps;
    // Deposit liquidity caps; see VaultInit.
    uint256 public depositCap;
    uint256 public perUserDepositCap;
    bool public capInToken0;
    address public capRaiser;
    // Transient within a rebalance: value of the position (token1 terms, TWAP)
    // snapshotted in beforeRebalance and consumed by onRebalance.
    uint256 internal rebalanceValueSnapshot;
    bytes internal addLiquidityExtraData;
    bytes public removeLiquidityExtraData;

    NftPosition public position;

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        VaultInit memory init
    ) Admin(admin_) {
        name = name_;
        symbol = symbol_;

        if (
            address(init.factory) == address(0)
                || address(init.nftFarmStrategy) == address(0)
                || address(init.automation) == address(0)
                || address(init.connectorRegistry) == address(0)
                || address(init.tokenIdResolver) == address(0)
                || address(init.liquidityAmountsResolver) == address(0)
                || init.nftManager == address(0) || init.pool == address(0)
                || init.twapWindow == 0
                || init.maxTickDeviation > MAX_TICK_DEVIATION_LIMIT
                || init.addLiquiditySlippageBps > BPS_BASIS
                || init.maxRebalanceLossBps > BPS_BASIS
                || (init.stakeEnabled && address(init.stakeSettingsRegistry) == address(0))
        ) {
            revert InvalidConfig();
        }

        nftFarmStrategy = init.nftFarmStrategy;
        automation = init.automation;
        connectorRegistry = init.connectorRegistry;
        tokenIdResolver = init.tokenIdResolver;
        liquidityAmountsResolver = init.liquidityAmountsResolver;
        nftManager = init.nftManager;
        pool = init.pool;
        poolId = init.poolId;
        twapWindow = init.twapWindow;
        maxTickDeviation = init.maxTickDeviation;
        maxRebalanceLossBps = init.maxRebalanceLossBps;
        addLiquiditySlippageBps = init.addLiquiditySlippageBps;
        inPlace = init.inPlace;
        stakeEnabled = init.stakeEnabled;
        stakeSettingsRegistry = init.stakeSettingsRegistry;
        addLiquidityExtraData = init.addLiquidityExtraData;
        removeLiquidityExtraData = init.removeLiquidityExtraData;
        depositCap = init.depositCap;
        perUserDepositCap = init.perUserDepositCap;
        capInToken0 = init.capInToken0;
        capRaiser = init.capRaiser;

        NftPoolInfo memory info = _poolInfo();
        if (info.token0 == address(0) || info.token1 == address(0)) {
            revert InvalidConfig();
        }
        token0 = info.token0;
        token1 = info.token1;

        sickle = Sickle(
            payable(init.factory
                    .deploy(address(init.automation), init.referralCode))
        );
        init.automation
            .setNftRebalanceCallback(
                sickle, INftRebalanceCallback(address(this))
            );
        init.automation
            .setNftDepositCallback(sickle, INftDepositCallback(address(this)));
        uint256 consent = AutomationPermissions.NFT_DUST_DEPOSIT
            | AutomationPermissions.NFT_COMPOUND
            | AutomationPermissions.NFT_REBALANCE;
        // Deliberately exclude NFT_REBALANCE_GENERIC. Vault rebalances must
        // use Automation.rebalanceFor so the callbacks above bracket the
        // strategy call and enforce the vault's value-loss invariant.
        // Opt the vault's Sickle into the stake-mode flip on the same rail.
        // The StakeStrategy's stakeFor/unstakeFor are dispatched through
        // Automation.executeFor, so they need owner consent like any other
        // automation action.
        if (stakeEnabled) {
            consent |= AutomationPermissions.STAKE_STAKE
                | AutomationPermissions.STAKE_UNSTAKE;
        }
        init.automation.setActionConsent(sickle, consent);
    }

    /// @notice The caller-supplied inputs to {initializePosition}. The vault
    /// fills in its own constants (token0/token1/fee/nft) when it builds the
    /// deposit, so only the position's free parameters live here.
    struct InitParams {
        Farm farm;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        bytes addLiquidityExtraData;
    }

    /// @notice One-time admin call that opens the vault's single CL position.
    /// @dev Lets {NftVaultCallLib.deposit} build the (otherwise heavy)
    /// NftDeposit from the vault's own constants (token0/token1/fee/nft). That
    /// keeps the struct encoder out of this size-critical vault and removes the
    /// need to validate a caller-supplied NftDeposit — the vault constructs a
    /// correct one by construction.
    function initializePosition(
        InitParams calldata p,
        NftSettings calldata settings,
        uint256 minShares
    )
        external
        onlyAdmin
        nonReentrant
        returns (uint256 tokenId, uint256 shares)
    {
        if (position.tokenId != 0) {
            revert PositionAlreadySet();
        }
        if (p.amount0Desired == 0 || p.amount1Desired == 0) {
            revert InvalidAmount();
        }

        _pullExact(token0, msg.sender, p.amount0Desired);
        _pullExact(token1, msg.sender, p.amount1Desired);
        _approveSickle(p.amount0Desired, p.amount1Desired);

        _openInitialPosition(p, settings);

        _clearSickleApprovals();
        tokenId = _nftTokenIdFor(
            NftPosition({
                farm: p.farm,
                nft: INonfungiblePositionManager(nftManager),
                tokenId: 0
            })
        );
        if (tokenId == 0) revert PositionNotSet();

        position = NftPosition({
            farm: p.farm,
            nft: INonfungiblePositionManager(nftManager),
            tokenId: tokenId
        });
        (,, uint128 liquidity) =
            _liquidityConnector().positionLiquidity(nftManager, tokenId);
        if (liquidity == 0) revert PositionNotSet();
        shares = uint256(liquidity);
        if (shares < minShares) revert Slippage();
        _mint(admin, shares);
        emit PositionSet(
            nftManager, tokenId, p.farm.stakingContract, p.farm.poolIndex
        );
    }

    /// @dev Offloads the deposit-args build + strategy call to
    /// {NftVaultCallLib}, keeping the heavy NftDeposit struct-encoder out of
    /// this size-critical vault so it stays under the EIP-170 bytecode limit.
    function _openInitialPosition(
        InitParams calldata p,
        NftSettings calldata settings
    ) private {
        NftVaultCallLib.deposit(
            nftFarmStrategy,
            NftVaultCallLib.DepositArgs({
                farm: p.farm,
                nft: INonfungiblePositionManager(nftManager),
                token0: token0,
                token1: token1,
                fee: _poolInfo().fee,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                amount0: p.amount0Desired,
                amount1: p.amount1Desired,
                amount0Min: p.amount0Min,
                amount1Min: p.amount1Min,
                addLiquidityExtraData: p.addLiquidityExtraData,
                sweepTokens: _sweepTokens()
            }),
            settings,
            address(automation)
        );
    }

    function setTwapConfig(
        uint32 twapWindow_,
        uint24 maxTickDeviation_,
        uint16 maxRebalanceLossBps_
    ) external onlyAdmin {
        if (
            twapWindow_ == 0 || maxRebalanceLossBps_ > BPS_BASIS
                || maxTickDeviation_ > MAX_TICK_DEVIATION_LIMIT
        ) {
            revert InvalidConfig();
        }
        twapWindow = twapWindow_;
        maxTickDeviation = maxTickDeviation_;
        maxRebalanceLossBps = maxRebalanceLossBps_;
    }

    /// @notice Sets the cap raiser, intended to be a dual-approval account for
    /// cap raises. The admin bootstraps the initial raiser; once it is nonzero
    /// only the current raiser can rotate it, so the admin cannot route around
    /// dual approval by re-pointing the gate at an admin-controlled address.
    function setCapRaiser(address capRaiser_) external {
        if (capRaiser == address(0)) {
            if (msg.sender != admin) revert NotAdminError();
        } else if (msg.sender != capRaiser) {
            revert NotCapRaiser();
        }
        capRaiser = capRaiser_;
    }

    /// @notice 0 disables a cap. Gated on capRaiser: when that is a
    /// dual-approval account, every cap change carries both approvals by
    /// construction — no on-chain propose/confirm needed.
    function setDepositCaps(
        uint256 newDepositCap,
        uint256 newPerUserDepositCap
    ) external {
        if (msg.sender != capRaiser) revert NotCapRaiser();
        _storeCaps(newDepositCap, newPerUserDepositCap);
    }

    /// @notice Lowers (tightens) either deposit cap without capRaiser approval.
    /// The provider (admin) may tighten caps unilaterally — e.g. to throttle inflows
    /// during an incident — but may never loosen them here (that needs setDepositCaps
    /// via the capRaiser). A cap of 0 means "disabled / unbounded", so it is treated
    /// as the maximum when checking that each cap only moves down or stays equal.
    function lowerDepositCaps(
        uint256 newDepositCap,
        uint256 newPerUserDepositCap
    ) external onlyAdmin {
        if (
            _capLoosened(depositCap, newDepositCap)
                || _capLoosened(perUserDepositCap, newPerUserDepositCap)
        ) {
            revert CapNotLowered();
        }
        _storeCaps(newDepositCap, newPerUserDepositCap);
    }

    /// @dev Stores cap values and emits the canonical cap-change event.
    function _storeCaps(
        uint256 newDepositCap,
        uint256 newPerUserDepositCap
    ) private {
        depositCap = newDepositCap;
        perUserDepositCap = newPerUserDepositCap;
        emit CapChanged(newDepositCap, newPerUserDepositCap);
    }

    /// @dev True if `next` is a looser (higher) cap than `current`, treating 0 as
    /// unbounded (the maximum). So 0->finite is a tightening (allowed); finite->0
    /// and finite->larger are looser (rejected).
    function _capLoosened(
        uint256 current,
        uint256 next
    ) private pure returns (bool) {
        uint256 curEff = current == 0 ? type(uint256).max : current;
        uint256 nextEff = next == 0 ? type(uint256).max : next;
        return nextEff > curEff;
    }

    /// @notice Current vault value (position + idle balances + uncollected
    /// fees), TWAP-valued in the cap token. Exposed for onchain value
    /// transparency; capInToken0 selects the denomination.
    function currentCapValue() public view returns (uint256) {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            _positionLiquidity();
        (uint256 fees0, uint256 fees1) = _earnedFees();
        return NftVaultTwapLib.vaultValue(
            liquidityAmountsResolver,
            pool,
            twapWindow,
            tickLower,
            tickUpper,
            liquidity,
            _poolTokenBalance(token0) + fees0,
            _poolTokenBalance(token1) + fees1,
            capInToken0
        );
    }

    /// @notice TWAP-valued price per share, scaled by 1e18, denominated in the cap
    /// token (token0 when capInToken0, else token1). Returns 0 before any shares
    /// exist. Uses the pool TWAP for position valuation. Idle balances enter the
    /// basis at their raw current amounts (TWAP-priced like the position), so
    /// direct token donations move the readout immediately.
    function pricePerShare() external view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return 0;
        return currentCapValue() * 1e18 / supply;
    }

    /// @dev Enforced after a deposit adds liquidity but before shares mint.
    /// Caps are expressed in pool *liquidity units*: the total cap bounds the
    /// position's liquidity; the per-user cap bounds the receiver's
    /// share-proportional slice of it. Either cap at 0 disables that check.
    /// Per-user cap is by share balance; shares are transferable, so it is a
    /// deposit-time guard, not a hard invariant.
    function _enforceDepositCap(
        uint128 liquidity,
        address receiver,
        uint256 mintShares,
        uint256 supplyBefore
    ) private view {
        uint256 totalCap = depositCap;
        uint256 userCap = perUserDepositCap;
        if (totalCap == 0 && userCap == 0) return;
        if (totalCap != 0 && liquidity > totalCap) revert DepositCapExceeded();
        if (userCap != 0) {
            uint256 newSupply = supplyBefore + mintShares;
            uint256 userLiquidity = newSupply == 0
                ? 0
                : (balanceOf[receiver] + mintShares) * uint256(liquidity)
                    / newSupply;
            if (userLiquidity > userCap) revert UserDepositCapExceeded();
        }
    }

    function setAddLiquidityExtraData(
        bytes calldata addLiquidityExtraData_
    ) external onlyAdmin {
        addLiquidityExtraData = addLiquidityExtraData_;
    }

    function setRemoveLiquidityExtraData(
        bytes calldata removeLiquidityExtraData_
    ) external onlyAdmin {
        removeLiquidityExtraData = removeLiquidityExtraData_;
    }

    function setNftSettings(
        NftSettings calldata settings
    ) external onlyAdmin {
        _requirePosition();
        nftFarmStrategy.nftSettingsRegistry()
            .setNftSettings(position.nft, position.tokenId, settings);
    }

    /// @notice Set the stake-mode auto-flip policy for this vault's position in
    /// the StakeSettingsRegistry (an ISettingsModule). The vault is the
    /// Sickle owner, so it writes through the registry's owner-keyed setter
    /// directly — the strategy only reads it (no bespoke config store, no
    /// owner-auth shim). The registry validates the policy and sets `enabled`.
    function setStakeConfig(
        StakeConfig calldata config
    ) external onlyAdmin {
        if (!stakeEnabled) revert NotStakeEnabled();
        _requirePosition();
        stakeSettingsRegistry.setConfig(
            NftKey({
                sickle: sickle,
                nftManager: position.nft,
                tokenId: position.tokenId
            }),
            config
        );
    }

    function beforeRebalance(
        Sickle sickle_,
        NftPosition calldata oldPosition
    ) external override nonReentrant {
        _requireAutomation(sickle_, oldPosition);
        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            _positionLiquidity();
        // Include the old position's uncollected LP fees: vault accounting
        // already treats fees as vault value (deposit `_earnedFees`, redeem
        // collection), so the floor must too — otherwise a rebalance could skim
        // the accrued fees and still satisfy the principal-only floor. The
        // post-rebalance value captures these once realized (swept to idle or
        // re-added as principal); the fresh new position has ~0 fees.
        (uint256 fees0, uint256 fees1) = _earnedFees();
        rebalanceValueSnapshot = NftVaultTwapLib.vaultValueInToken1(
            liquidityAmountsResolver,
            pool,
            twapWindow,
            tickLower,
            tickUpper,
            liquidity,
            _poolTokenBalance(token0) + fees0,
            _poolTokenBalance(token1) + fees1
        );
    }

    function onRebalance(
        Sickle sickle_,
        NftPosition calldata oldPosition
    ) external override nonReentrant {
        _requireAutomation(sickle_, oldPosition);
        uint256 newTokenId = _nftTokenIdFor(oldPosition);
        if (newTokenId == 0) revert PositionNotSet();
        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            _liquidityConnector().positionLiquidity(nftManager, newTokenId);
        if (liquidity == 0) revert PositionNotSet();
        _requireVaultSicklePosition(newTokenId);

        // Value floor: the rebalanced position, valued at the TWAP price, must
        // retain at least (1 - maxRebalanceLossBps) of the pre-rebalance value
        // snapshotted in beforeRebalance. Fail closed if no snapshot was taken.
        uint256 snapshot = rebalanceValueSnapshot;
        rebalanceValueSnapshot = 0;
        if (snapshot == 0) revert RebalanceValueLoss();
        uint256 newValue = NftVaultTwapLib.vaultValueInToken1(
            liquidityAmountsResolver,
            pool,
            twapWindow,
            tickLower,
            tickUpper,
            liquidity,
            _poolTokenBalance(token0),
            _poolTokenBalance(token1)
        );
        if (
            newValue * BPS_BASIS
                < snapshot * (BPS_BASIS - maxRebalanceLossBps)
        ) {
            revert RebalanceValueLoss();
        }

        position.tokenId = newTokenId;

        emit PositionSet(
            address(position.nft),
            newTokenId,
            position.farm.stakingContract,
            position.farm.poolIndex
        );
    }

    function recoverToken(
        address token,
        address receiver,
        uint256 amount
    ) external onlyAdmin nonReentrant {
        if (token == address(0) || receiver == address(0)) {
            revert InvalidConfig();
        }
        if (
            token == token0 || token == token1 || token == address(this)
                || _isProtectedToken(token)
        ) {
            revert InvalidToken();
        }

        token.safeTransfer(receiver, amount);
        emit TokenRecovered(token, receiver, amount);
    }

    function deposit(
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint256 minShares,
        address receiver
    ) external nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) revert InvalidConfig();
        _requirePosition();
        _checkTwap();

        DepositCache memory cache;
        cache.poolInfo = _poolInfo();
        (cache.tickLower, cache.tickUpper, cache.liquidityBefore) =
            _positionLiquidity();
        if (cache.liquidityBefore == 0) revert PositionNotSet();

        (cache.currentAmount0, cache.currentAmount1) = _amountsForLiquidity(
            cache.poolInfo.sqrtPriceX96,
            cache.tickLower,
            cache.tickUpper,
            cache.liquidityBefore
        );
        if (cache.currentAmount0 == 0 || cache.currentAmount1 == 0) {
            revert PositionOutOfRange();
        }
        (cache.vaultAmount0, cache.vaultAmount1) = _earnedFees();
        cache.vaultAmount0 += _poolTokenBalance(token0);
        cache.vaultAmount1 += _poolTokenBalance(token1);
        (cache.amount0, cache.amount1) = _quoteDepositAmounts(
            maxAmount0, maxAmount1, cache.currentAmount0, cache.currentAmount1
        );

        _pullExact(token0, msg.sender, cache.amount0);
        _pullExact(token1, msg.sender, cache.amount1);
        _increasePosition(
            cache.amount0,
            cache.amount1,
            cache.tickLower,
            cache.tickUpper,
            cache.poolInfo.fee
        );

        (,, uint128 liquidityAfter) = _positionLiquidity();
        cache.liquidityDelta = uint256(liquidityAfter - cache.liquidityBefore);
        if (cache.liquidityDelta == 0) revert Slippage();

        uint256 supply = totalSupply;
        if (supply == 0) {
            shares = cache.liquidityDelta;
        } else {
            shares =
                cache.liquidityDelta * supply / uint256(cache.liquidityBefore);
            uint256 amountShares0 = cache.amount0 * supply
                / (cache.currentAmount0 + cache.vaultAmount0);
            uint256 amountShares1 = cache.amount1 * supply
                / (cache.currentAmount1 + cache.vaultAmount1);
            if (amountShares1 < amountShares0) amountShares0 = amountShares1;
            if (amountShares0 < shares) shares = amountShares0;
        }
        if (shares == 0 || shares < minShares) revert Slippage();

        _enforceDepositCap(liquidityAfter, receiver, shares, supply);

        _mint(receiver, shares);
    }

    function redeem(
        uint256 shares,
        uint256 minAmount0,
        uint256 minAmount1,
        address receiver
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidConfig();
        _requirePosition();

        RedeemCache memory cache;
        cache.supply = totalSupply;
        (
            cache.liquidityToRemove,
            cache.fullWithdraw,
            cache.amount0Max,
            cache.amount1Max
        ) = _redeemLiquidity(shares, cache.supply);

        cache.balance0Before = _poolTokenBalance(token0);
        cache.balance1Before = _poolTokenBalance(token1);

        if (cache.fullWithdraw) {
            _withdrawPosition(
                type(uint128).max,
                minAmount0,
                minAmount1,
                cache.amount0Max,
                cache.amount1Max
            );
            delete position;
        } else {
            _decreasePosition(
                cache.liquidityToRemove,
                minAmount0,
                minAmount1,
                cache.amount0Max,
                cache.amount1Max
            );
        }

        amount0 = _poolTokenBalance(token0);
        amount1 = _poolTokenBalance(token1);
        if (!cache.fullWithdraw) {
            amount0 -= cache.balance0Before;
            amount1 -= cache.balance1Before;
        }
        if (amount0 < minAmount0 || amount1 < minAmount1) revert Slippage();

        _burn(msg.sender, shares);

        token0.safeTransfer(receiver, amount0);
        token1.safeTransfer(receiver, amount1);
    }

    function beforeDeposit(
        Sickle sickle_,
        NftPosition calldata position_,
        NftIncrease calldata increase
    ) external override nonReentrant {
        _requireAutomation(sickle_, position_);
        if (increase.zap.addLiquidityParams.tokenId != position.tokenId) {
            revert InvalidConfig();
        }

        address[] calldata tokens = increase.tokensIn;
        uint256[] calldata amounts = increase.amountsIn;
        if (tokens.length != amounts.length) revert InvalidAmount();

        uint256 amount0;
        uint256 amount1;
        for (uint256 i; i < tokens.length;) {
            address token = tokens[i];
            if (token == token0) amount0 += amounts[i];
            else if (token == token1) amount1 += amounts[i];
            else revert InvalidToken();
            unchecked {
                ++i;
            }
        }
        _approveSickle(amount0, amount1);
    }

    function transfer(
        address to,
        uint256 amount
    ) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function approve(
        address spender,
        uint256 amount
    ) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        if (to == address(0)) revert InvalidConfig();
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _mint(
        address to,
        uint256 amount
    ) internal virtual {
        if (to == address(0)) revert InvalidConfig();
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function _burn(
        address from,
        uint256 amount
    ) internal virtual {
        balanceOf[from] -= amount;
        unchecked {
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _requirePosition() internal view {
        if (position.tokenId == 0) revert PositionNotSet();
    }

    function _checkTwap() internal view {
        NftVaultTwapLib.checkTwap(
            pool, twapWindow, maxTickDeviation, _poolInfo().tick
        );
    }

    function _quoteDepositAmounts(
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint256 currentAmount0,
        uint256 currentAmount1
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (maxAmount0 == 0 || maxAmount1 == 0) revert InvalidAmount();

        uint256 amount1FromMax0 = maxAmount0 * currentAmount1 / currentAmount0;
        if (amount1FromMax0 <= maxAmount1) {
            amount0 = maxAmount0;
            amount1 = amount1FromMax0;
        } else {
            amount1 = maxAmount1;
            amount0 = maxAmount1 * currentAmount0 / currentAmount1;
        }

        if (amount0 == 0 || amount1 == 0) revert InvalidAmount();
    }

    function _nftTokenIdFor(
        NftPosition memory position_
    ) internal view returns (uint256) {
        return tokenIdResolver.tokenIdOf(sickle, position_);
    }

    function _requireAutomation(
        Sickle sickle_,
        NftPosition calldata position_
    ) internal view {
        if (msg.sender != address(automation)) revert NotAutomation();
        if (sickle_ != sickle) revert InvalidSickle();
        _requireCurrentPosition(position_);
    }

    function _requireCurrentPosition(
        NftPosition calldata position_
    ) internal view {
        if (
            address(position_.nft) != address(position.nft)
                || position_.tokenId != position.tokenId
                || position_.farm.stakingContract
                    != position.farm.stakingContract
                || position_.farm.poolIndex != position.farm.poolIndex
        ) {
            revert InvalidConfig();
        }
    }

    function _earnedFees()
        internal
        view
        returns (uint256 fees0, uint256 fees1)
    {
        return _liquidityConnector()
            .earnedFees(nftManager, pool, position.tokenId);
    }

    function _redeemLiquidity(
        uint256 shares,
        uint256 supply
    )
        internal
        view
        returns (
            uint128 liquidityToRemove,
            bool fullWithdraw,
            uint128 amount0Max,
            uint128 amount1Max
        )
    {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            _positionLiquidity();
        liquidityToRemove = uint128(uint256(liquidity) * shares / supply);
        if (liquidityToRemove == 0) revert InvalidAmount();

        fullWithdraw = shares == supply;
        if (fullWithdraw) {
            amount0Max = type(uint128).max;
            amount1Max = type(uint128).max;
        } else {
            (amount0Max, amount1Max) = _collectMax(
                liquidityToRemove, shares, supply, tickLower, tickUpper
            );
        }
    }

    function _collectMax(
        uint128 liquidityToRemove,
        uint256 shares,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint128 amount0Max, uint128 amount1Max) {
        NftPoolInfo memory poolInfo = _poolInfo();
        (uint256 principal0, uint256 principal1) = _amountsForLiquidity(
            poolInfo.sqrtPriceX96, tickLower, tickUpper, liquidityToRemove
        );
        (uint256 fees0, uint256 fees1) = _earnedFees();
        amount0Max = _toUint128Max(principal0 + fees0 * shares / supply + 1);
        amount1Max = _toUint128Max(principal1 + fees1 * shares / supply + 1);
    }

    function _toUint128Max(
        uint256 amount
    ) internal pure returns (uint128) {
        if (amount > type(uint128).max) return type(uint128).max;
        return uint128(amount);
    }

    function _amountsForLiquidity(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256 amount0, uint256 amount1) {
        return liquidityAmountsResolver.amountsForLiquidity(
            sqrtPriceX96, tickLower, tickUpper, liquidity
        );
    }

    function _positionLiquidity()
        internal
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        return _liquidityConnector()
            .positionLiquidity(address(position.nft), position.tokenId);
    }

    function _requireVaultSicklePosition(
        uint256 tokenId
    ) internal view {
        INftLiquidityConnector liquidityConnector = _liquidityConnector();
        NftPoolKey memory key = liquidityConnector.positionPoolKey(
            IUniswapV3Pool(pool).factory(), nftManager, tokenId
        );
        if (key.poolAddress != pool || key.poolId != poolId) {
            revert InvalidConfig();
        }

        if (position.nft.ownerOf(tokenId) == address(sickle)) {
            return;
        }

        NftPosition memory candidate = NftPosition({
            farm: position.farm, nft: position.nft, tokenId: tokenId
        });
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);
        if (!INftFarmConnector(farmConnector)
                .isStaked(address(sickle), candidate)) {
            revert InvalidSickle();
        }
    }

    function _poolInfo() internal view returns (NftPoolInfo memory) {
        return _liquidityConnector().poolInfo(pool, poolId);
    }

    function _liquidityConnector()
        internal
        view
        returns (INftLiquidityConnector)
    {
        return INftLiquidityConnector(connectorRegistry.connectorOf(nftManager));
    }

    /// @dev True when the position NFT is currently gauge-staked (earning AERO).
    /// When the StakeStrategy has flipped it unstaked, the NFT is held by
    /// the Sickle and earns swap fees instead — so stake-mode liquidity ops run
    /// in place (no gauge withdraw/deposit). Reward harvest still runs in both
    /// modes (the gauge connector is idempotent and sweeps any reward the gauge
    /// paid to the Sickle); this flag only gates the in-place liquidity path.
    function _currentlyStaked() internal view returns (bool) {
        if (position.tokenId == 0) return false;
        return INftFarmConnector(
            connectorRegistry.connectorOf(position.farm.stakingContract)
        ).isStaked(address(sickle), position);
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

    function _isProtectedToken(
        address
    ) internal view virtual returns (bool) {
        return false;
    }

    function _poolTokenBalance(
        address token
    ) internal view virtual returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function _approveSickle(
        uint256 amount0,
        uint256 amount1
    ) internal {
        if (
            amount0 > _poolTokenBalance(token0)
                || amount1 > _poolTokenBalance(token1)
        ) {
            revert InvalidAmount();
        }
        token0.safeApprove(address(sickle), 0);
        token0.safeApprove(address(sickle), amount0);
        token1.safeApprove(address(sickle), 0);
        token1.safeApprove(address(sickle), amount1);
    }

    function _clearSickleApprovals() internal {
        token0.safeApprove(address(sickle), 0);
        token1.safeApprove(address(sickle), 0);
    }

    function _increasePosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee
    ) internal virtual {
        _approveSickle(amount0, amount1);

        NftVaultCallLib.increase(
            nftFarmStrategy,
            position,
            NftVaultCallLib.IncreaseArgs({
                token0: token0,
                token1: token1,
                amount0: amount0,
                amount1: amount1,
                tickLower: tickLower,
                tickUpper: tickUpper,
                fee: fee,
                slippageBps: addLiquiditySlippageBps,
                // stake-mode + unstaked -> modify in place, no gauge op
                inPlace: inPlace || (stakeEnabled && !_currentlyStaked()),
                addLiquidityExtraData: addLiquidityExtraData,
                rewardTokens: _harvestRewardTokens(),
                sweepTokens: _sweepTokens()
            })
        );

        _clearSickleApprovals();
    }

    function _withdrawPosition(
        uint128 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal virtual {
        address[] memory sweepTokens = _sweepTokens();
        NftVaultCallLib.withdraw(
            nftFarmStrategy,
            position,
            liquidity,
            minAmount0,
            minAmount1,
            amount0Max,
            amount1Max,
            removeLiquidityExtraData,
            sweepTokens
        );
    }

    function _decreasePosition(
        uint128 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal virtual {
        address[] memory rewardTokens = _harvestRewardTokens();
        address[] memory sweepTokens = _sweepTokens();
        bool modifyInPlace =
            inPlace || (stakeEnabled && !_currentlyStaked());
        NftVaultCallLib.decrease(
            nftFarmStrategy,
            position,
            liquidity,
            minAmount0,
            minAmount1,
            amount0Max,
            amount1Max,
            removeLiquidityExtraData,
            modifyInPlace,
            rewardTokens,
            sweepTokens
        );
    }

    /// @dev Reward tokens harvested alongside increase/decrease. Empty for the
    /// base (fee-only) vault; overridden by the harvest vault when it harvests
    /// in-line. The harvest vault deliberately passes an empty array here
    /// because it harvests rewards separately via _harvestReward.
    function _harvestRewardTokens()
        internal
        view
        virtual
        returns (address[] memory)
    {
        return new address[](0);
    }

    function _sweepTokens()
        internal
        view
        virtual
        returns (address[] memory tokens)
    {
        return _poolSweepTokens();
    }

    function _poolSweepTokens()
        internal
        view
        returns (address[] memory tokens)
    {
        tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
    }
}

/// @dev Used for fee-only vaults where LP fees are compounded by automation.
contract NftFarmCompoundVault is NftFarmVault {
    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        VaultInit memory init
    ) NftFarmVault(name_, symbol_, admin_, init) { }
}

contract NftFarmHarvestVault is NftFarmVault {
    using SafeTransferLib for address;

    uint256 internal accRewardPerShare;
    uint256 internal trackedRewardBalance;
    mapping(address => uint256) internal rewardDebt;
    mapping(address => uint256) public claimableReward;

    address internal immutable rewardToken;
    uint256 private constant ACC_REWARD_PRECISION = 1e18;

    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        VaultInit memory init,
        address rewardToken_
    ) NftFarmVault(name_, symbol_, admin_, init) {
        if (rewardToken_ == address(0) || rewardToken_ == address(this)) {
            revert InvalidConfig();
        }
        rewardToken = rewardToken_;
    }

    function claim(
        address receiver
    ) external nonReentrant returns (uint256 amount) {
        if (receiver == address(0)) revert InvalidConfig();

        _harvestReward();
        _syncReward();
        _checkpoint(msg.sender);

        amount = claimableReward[msg.sender];
        claimableReward[msg.sender] = 0;
        trackedRewardBalance -= amount;

        rewardToken.safeTransfer(receiver, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        _syncReward();
        _checkpoint(from);
        _checkpoint(to);

        super._transfer(from, to, amount);

        _updateRewardDebt(from);
        _updateRewardDebt(to);
    }

    function _mint(
        address to,
        uint256 amount
    ) internal override {
        _syncReward();
        _checkpoint(to);

        super._mint(to, amount);

        _updateRewardDebt(to);
    }

    function _burn(
        address from,
        uint256 amount
    ) internal override {
        _syncReward();
        _checkpoint(from);

        super._burn(from, amount);

        _updateRewardDebt(from);
    }

    function _sweepTokens()
        internal
        view
        override
        returns (address[] memory tokens)
    {
        if (rewardToken == token0 || rewardToken == token1) {
            return super._sweepTokens();
        }
        tokens = new address[](3);
        tokens[0] = token0;
        tokens[1] = token1;
        tokens[2] = rewardToken;
    }

    function _isProtectedToken(
        address token
    ) internal view override returns (bool) {
        return token == rewardToken;
    }

    function _poolTokenBalance(
        address token
    ) internal view override returns (uint256 balance) {
        balance = super._poolTokenBalance(token);
        if (token == rewardToken) {
            uint256 rewards = trackedRewardBalance;
            if (balance <= rewards) return 0;
            balance -= rewards;
        }
    }

    function _withdrawPosition(
        uint128 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal override {
        _harvestReward();
        super._withdrawPosition(
            liquidity, minAmount0, minAmount1, amount0Max, amount1Max
        );
    }

    function _decreasePosition(
        uint128 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal override {
        _harvestReward();
        super._decreasePosition(
            liquidity, minAmount0, minAmount1, amount0Max, amount1Max
        );
    }

    function _increasePosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee
    ) internal override {
        _harvestReward();
        super._increasePosition(amount0, amount1, tickLower, tickUpper, fee);
    }

    function _syncReward() internal {
        if (rewardToken == token0 || rewardToken == token1) return;
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (balance > trackedRewardBalance) {
            _syncRewardDelta(balance - trackedRewardBalance);
        }
    }

    function _syncRewardDelta(
        uint256 delta
    ) private {
        if (delta == 0) return;
        uint256 supply = totalSupply;
        if (supply == 0) {
            trackedRewardBalance += delta;
            return;
        }

        accRewardPerShare += delta * ACC_REWARD_PRECISION / supply;
        trackedRewardBalance += delta;
    }

    function _checkpoint(
        address account
    ) internal {
        uint256 accumulated =
            balanceOf[account] * accRewardPerShare / ACC_REWARD_PRECISION;
        uint256 pending = accumulated - rewardDebt[account];
        if (pending > 0) {
            claimableReward[account] += pending;
        }
        rewardDebt[account] = accumulated;
    }

    function _updateRewardDebt(
        address account
    ) private {
        rewardDebt[account] =
            balanceOf[account] * accRewardPerShare / ACC_REWARD_PRECISION;
    }

    function _rewardTokens() private view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = rewardToken;
    }

    function _harvestReward() private {
        if (position.tokenId == 0) return;
        // Runs in every mode. When the StakeStrategy has flipped the
        // position unstaked, SlipstreamGaugeConnector.claim skips getReward
        // (idempotent, no revert) — but the harvest's sweep still pulls any
        // reward the gauge already paid to the Sickle (e.g. the pending AERO
        // gauge.withdraw pays out at the unstake flip) into the vault, where
        // _syncRewardDelta below accounts it. Skipping here would strand that
        // reward on the Sickle until the next liquidity op (claim would return
        // 0; a transfer could mis-attribute it).
        uint256 balanceBefore = IERC20(rewardToken).balanceOf(address(this));
        NftVaultCallLib.harvest(nftFarmStrategy, position, _rewardTokens());
        uint256 balanceAfter = IERC20(rewardToken).balanceOf(address(this));
        if (balanceAfter > balanceBefore) {
            _syncRewardDelta(balanceAfter - balanceBefore);
        }
    }
}
