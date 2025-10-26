// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// ═══════════════════════════════════════════════════════════
// INTERFACES
// ═══════════════════════════════════════════════════════════

interface IShieldVault {
    function totalSupply() external view returns (uint256);
}

interface IBasketOracle {
    function getNAVPerToken(uint256 supply) external view returns (uint256);
}

interface IGMXV2PositionManager {
    struct PositionInfo {
        address market;
        address collateralToken;
        uint256 sizeInUsd;
        uint256 collateralAmount;
        bool isLong;
        bytes32 positionKey;
        uint256 lastUpdateTime;
    }

    function openPosition(
        address market,
        address collateralToken,
        uint256 collateralAmount,
        uint256 sizeDeltaUsd,
        bool isLong,
        uint16 slippageBps
    ) external payable returns (bytes32 orderKey);

    function closePosition(
        bytes32 positionKey,
        uint256 sizeDeltaUsd,
        uint16 slippageBps
    ) external payable returns (bytes32 orderKey);

    function getPositionValue(
        bytes32 positionKey
    ) external view returns (uint256 valueUsd);

    function getPosition(
        bytes32 positionKey
    ) external view returns (PositionInfo memory);
}

// ═══════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════
error VaultAlreadySet();
error ZeroAddress();
error ZeroAmount();
error InvalidAmount();
error InvalidRecipient();
error StablecoinNotSupported();
error StablecoinAlreadyAdded();
error InsufficientReserves();
error InsufficientBalance();
error ReserveRatioTooLow();
error ExceedsWithdrawalLimit();
error ExceedsSingleWithdrawalLimit();
error ExceedsDailyWithdrawalLimit();
error InvalidDecimals();
error InvalidAllocation();
error ReservesNotZero();
error NotActive();
error AlreadyApproved();
error NotApproved();
error FundsStillAllocated();
error InvalidCooldown();
error MustBePaused();
error CooldownActive();
error RebalanceInProgress();
error CannotRecoverManagedToken();
error YieldProtocolNotApproved();
error TransferFailed();
error GMXPositionOpenFailed();
error GMXPositionCloseFailed();
error ExcessiveIdleCapital();
error InvalidMarket();
error InsufficientExecutionFee();
error PositionNotFound();
error DeploymentFailed();

// ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
// BASKET MANAGER- This is like our core contract after feedback #1 we had to migrate to real exposure instead of synthetic kinda thing
// ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

/**
 * @title BasketManager - MIGRATED TO GMX V2 PERPS
 * @notice Manages commodity index backing via GMX perpetual futures
 */
contract BasketManager is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ═══════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MIN_RESERVE_RATIO = 9500; // 95%
    uint256 public constant TARGET_RESERVE_RATIO = 10000; // 100%
    uint256 public constant CRITICAL_RESERVE_RATIO = 9000; // 90%
    uint256 public constant MAX_SINGLE_WITHDRAWAL_BPS = 1000; // 10%
    uint256 public constant MAX_DAILY_WITHDRAWAL_BPS = 2000; // 20%
    uint256 public constant MIN_REBALANCE_COOLDOWN = 1 hours;
    uint256 public constant MAX_REBALANCE_COOLDOWN = 7 days;

    // ═══  GMX-SPECIFIC CONSTANTS ═══
    uint256 public constant MIN_DEPLOYMENT_AMOUNT = 100e6; // 100 USDC min
    uint256 public constant MAX_IDLE_CAPITAL_BPS = 200; // 2% max idle
    uint256 public constant GMX_EXECUTION_FEE = 0.001 ether; // Per order
    uint256 public constant POSITION_LEVERAGE = 1; // 1x only (no liquidation risk)
    uint256 public constant POSITION_VALUE_STALE_THRESHOLD = 15 minutes;
    uint16 public constant DEFAULT_SLIPPAGE_BPS = 30; // 0.3%

    // ═══════════════════════════════════════════════════════════
    // ROLES
    // ═══════════════════════════════════════════════════════════

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant YIELD_MANAGER_ROLE =
        keccak256("YIELD_MANAGER_ROLE");
    bytes32 public constant GMX_CALLBACK_ROLE = keccak256("GMX_CALLBACK_ROLE");

    // ═══════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════

    /// @notice Stablecoin configuration
    struct StablecoinConfig {
        address token;
        uint8 decimals;
        bool isActive;
        uint256 reserves; //only for pending deposits
        uint256 targetAllocationBps;
    }

    /// @notice  Commodity basket allocation
    struct CommodityAllocation {
        address market; // GMX market address
        address indexToken; // Underlying asse
        string name; // Human-readable name
        uint16 targetWeightBps; // Target weight (e.g., 2000 = 20%)
        bool isLong; // Always true for commodities
        bytes32 currentPositionKey; // Active GMX position key
        bytes32 pendingOrderKey; // Pending GMX order key
        uint256 lastUpdateTime; // Last position update timestamp
        uint256 targetSizeUsd; // Target position size in USD (30 decimals)
        bool isActive; // Whether this allocation is active
        uint256 lastKnownValue;
    }

    /// @notice  Pending deposit queue (for async GMX execution)
    struct PendingDeposit {
        address user;
        uint256 amount;
        uint256 timestamp;
        bytes32[] associatedOrders; // GMX order keys
        bool isProcessed;
    }

    /// @notice  Pending withdrawal queue
    struct PendingWithdrawal {
        address user;
        uint256 amount;
        uint256 timestamp;
        bytes32[] associatedOrders; // GMX close order keys
        bool isProcessed;
    }

    mapping(address => StablecoinConfig) public stablecoins;
    address[] public supportedStablecoins;

    uint256 public totalReservesUSD; //  includes GMX position values
    uint256 public lifetimeDeposits;
    uint256 public lifetimeWithdrawals;
    uint256 public totalYieldGenerated;
    uint256 public dailyWithdrawalVolume;
    uint256 public lastWithdrawalReset;

    bool public rebalanceInProgress;
    uint256 public lastRebalanceTime;
    uint256 public rebalanceCooldown;

    IShieldVault public shieldVault;
    IBasketOracle public immutable oracle;

    /// @notice GMX position manager (wrapper around GMX V2)
    IGMXV2PositionManager public immutable gmxPositionManager;

    /// @notice Primary collateral token (USDC)
    IERC20 public immutable usdc;

    /// @notice Commodity basket
    CommodityAllocation[] public basket;
    /// @notice Total weight of all basket components (should equal BPS_DENOMINATOR)
    uint256 public totalWeightBps;
    /// @notice Pending deployment amount (before GMX orders execute)
    uint256 public pendingDeployment;

    /// @notice Total value in GMX positions (cached)
    uint256 public totalGMXPositionValue;

    /// @notice Last position value update timestamp
    uint256 public lastPositionValueUpdate;

    /// @notice Pending deposit queue
    mapping(uint256 => PendingDeposit) public pendingDeposits;
    uint256 public pendingDepositCount;

    /// @notice Pending withdrawal queue
    mapping(uint256 => PendingWithdrawal) public pendingWithdrawals;
    uint256 public pendingWithdrawalCount;

    /// @notice Order key >> deposit ID mapping
    mapping(bytes32 => uint256) public orderToDepositId;

    /// @notice Order key >> withdrawal ID mapping
    mapping(bytes32 => uint256) public orderToWithdrawalId;

    /// @notice Order key >> basket index mapping
    mapping(bytes32 => uint256) public orderToBasketIndex;

    /// @notice Emergency buffer (kept as USDC for instant withdrawals)
    uint256 public emergencyBufferUSD;

    /// @notice Target emergency buffer ratio (5% default)
    uint256 public targetEmergencyBufferBps;

    // ═══════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════

    // Existing events
    event StablecoinAdded(
        address indexed token,
        uint8 decimals,
        uint256 targetAllocationBps
    );
    event StablecoinRemoved(address indexed token);
    event TargetAllocationUpdated(
        address indexed token,
        uint256 oldAllocation,
        uint256 newAllocation
    );
    event ReservesDeposited(
        address indexed from,
        address indexed token,
        uint256 amount,
        uint256 usdValue
    );
    event ReservesWithdrawn(
        address indexed to,
        address indexed token,
        uint256 amount,
        uint256 usdValue
    );
    event ReserveRatioUpdated(
        uint256 reserveRatio,
        uint256 totalReserves,
        uint256 shieldSupply
    );
    event RebalanceExecuted(
        address indexed fromToken,
        address indexed toToken,
        uint256 amount,
        uint256 timestamp
    );
    event EmergencyWithdrawal(
        address indexed recipient,
        address indexed token,
        uint256 amount,
        string reason
    );
    event EmergencyShutdown(address indexed by, string reason);
    event RebalanceCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event TokensRecovered(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    event CapitalDeployed(
        uint256 indexed depositId,
        uint256 basketIndex,
        address indexed market,
        uint256 collateralAmount,
        uint256 sizeDeltaUsd,
        bytes32 orderKey
    );

    event PositionOpened(
        bytes32 indexed positionKey,
        uint256 indexed basketIndex,
        address market,
        uint256 sizeUsd,
        uint256 collateralUsd,
        uint256 timestamp
    );

    event PositionIncreased(
        bytes32 indexed positionKey,
        uint256 basketIndex,
        uint256 sizeDeltaUsd,
        uint256 collateralDeltaUsd
    );

    event PositionClosed(
        bytes32 indexed positionKey,
        uint256 indexed withdrawalId,
        uint256 basketIndex,
        uint256 sizeUsd,
        int256 realizedPnl
    );

    event PositionDecreased(
        bytes32 indexed positionKey,
        uint256 basketIndex,
        uint256 sizeDeltaUsd,
        uint256 collateralDeltaUsd,
        int256 realizedPnl
    );

    event GMXOrderSubmitted(
        bytes32 indexed orderKey,
        uint256 indexed requestId, // depositId or withdrawalId
        uint256 basketIndex,
        bool isIncrease,
        uint256 timestamp
    );

    event GMXOrderExecuted(
        bytes32 indexed orderKey,
        bytes32 indexed positionKey,
        uint256 basketIndex,
        bool success
    );

    event GMXOrderFailed(
        bytes32 indexed orderKey,
        uint256 basketIndex,
        string reason
    );

    event DepositProcessed(
        uint256 indexed depositId,
        address indexed user,
        uint256 amount,
        bool success
    );

    event WithdrawalProcessed(
        uint256 indexed withdrawalId,
        address indexed user,
        uint256 amount,
        bool success
    );

    event IdleCapitalWarning(
        uint256 idleAmount,
        uint256 totalValue,
        uint256 idlePercentageBps
    );

    event PositionValueUpdated(
        uint256 totalValue,
        uint256 gmxValue,
        uint256 reserveValue,
        uint256 timestamp
    );

    event EmergencyBufferUpdated(uint256 oldBufferBps, uint256 newBufferBps);

    event BasketAllocationAdded(
        uint256 indexed basketIndex,
        address indexed market,
        string name,
        uint16 weightBps
    );

    event BasketAllocationUpdated(
        uint256 indexed basketIndex,
        uint16 oldWeightBps,
        uint16 newWeightBps
    );

    // ═══════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor(
        address _oracle,
        address _shieldVault,
        address _gmxPositionManager,
        address _usdc,
        address _admin
    ) {
        if (_oracle == address(0)) revert ZeroAddress();
        if (_gmxPositionManager == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        oracle = IBasketOracle(_oracle);
        shieldVault = IShieldVault(_shieldVault);
        gmxPositionManager = IGMXV2PositionManager(_gmxPositionManager);
        usdc = IERC20(_usdc);

        // Grant roles
        if (_shieldVault != address(0)) {
            _grantRole(VAULT_ROLE, _shieldVault);
        }
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(REBALANCER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(YIELD_MANAGER_ROLE, _admin);
        _grantRole(GMX_CALLBACK_ROLE, _gmxPositionManager);

        // Initialize parameters
        rebalanceCooldown = 1 hours;
        lastWithdrawalReset = block.timestamp;
        targetEmergencyBufferBps = 500; // 5% emergency buffer

        // Add USDC as primary stablecoin
        stablecoins[_usdc] = StablecoinConfig({
            token: _usdc,
            decimals: 6,
            isActive: true,
            reserves: 0,
            targetAllocationBps: BPS_DENOMINATOR // 100% USDC
        });
        supportedStablecoins.push(_usdc);

        // Initialize basket with default allocations
        // NOTE: we have to set real GMX market addresses when we deploy/prod mode
        _initializeDefaultBasket();
    }
    /**
     * @notice Set ShieldVault address (can only be called once)
     * @param _vault Address of ShieldVault contract
     */
    function setShieldVault(
        address _vault
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_vault == address(0)) revert ZeroAddress();
        if (address(shieldVault) != address(0)) revert VaultAlreadySet();

        shieldVault = IShieldVault(_vault);
        _grantRole(VAULT_ROLE, _vault);
    }
    // ═══════════════════════════════════════════════════════════
    // CORE RESERVE OPERATIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Deposit stablecoins >> IMMEDIATELY deploy to GMX positions
     * @param token Stablecoin address (USDC)
     * @param amount Amount to deposit (6 decimals for USDC)
     * @param from User address
     *
    /**
     * @notice Deposit stablecoins >> IMMEDIATELY deploy to GMX positions
     */
    function depositReserves(
        address token,
        uint256 amount,
        address from
    ) external payable onlyRole(VAULT_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        StablecoinConfig storage stablecoin = stablecoins[token];
        if (!stablecoin.isActive) revert StablecoinNotSupported();

        uint256 usdValue = _normalizeAmount(amount, stablecoin.decimals);

        // Pull from msg.sender (ShieldVault), not from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update state AFTER successful transfer (CEI pattern)
        stablecoin.reserves += amount;
        pendingDeployment += amount;
        lifetimeDeposits += usdValue;

        // Create pending deposit record (use `from` for user tracking)
        uint256 depositId = pendingDepositCount++;
        pendingDeposits[depositId] = PendingDeposit({
            user: from, // Original user for events/tracking
            amount: amount,
            timestamp: block.timestamp,
            associatedOrders: new bytes32[](0),
            isProcessed: false
        });

        emit ReservesDeposited(from, token, amount, usdValue);

        // Deploy to GMX if threshold met
        if (pendingDeployment >= MIN_DEPLOYMENT_AMOUNT) {
            _deployCapitalToGMX(depositId);
        }

        _updateTotalReserves();
        _checkIdleCapitalRatio();
    }
    /**
     * @notice Withdraw stablecoins >> Close GMX positions first
     * @param token Stablecoin to receive
     * @param amount Amount needed (6 decimals for USDC)
     * @param to Recipient
     
    /**
     * @notice Withdraw stablecoins >> Close GMX positions first
     */
    function withdrawReserves(
        address token,
        uint256 amount,
        address to
    ) external payable onlyRole(VAULT_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert InvalidRecipient();

        StablecoinConfig storage stablecoin = stablecoins[token];
        if (!stablecoin.isActive) revert StablecoinNotSupported();

        uint256 usdValue = _normalizeAmount(amount, stablecoin.decimals);
        _checkWithdrawalLimits(usdValue);

        //  Check emergency buffer BEFORE withdrawal
        uint256 availableReserves = stablecoin.reserves;
        if (availableReserves >= amount) {
            // Check emergency buffer enforcement
            uint256 remainingReserves = availableReserves - amount;
            uint256 requiredBuffer = (getTotalManagedValue() *
                targetEmergencyBufferBps) / BPS_DENOMINATOR;

            if (remainingReserves < requiredBuffer) {
                revert("Would breach emergency buffer");
            }

            //  FIXED: External call BEFORE state updates
            IERC20(token).safeTransfer(to, amount);

            //  State updates AFTER external call (CEI pattern)
            stablecoin.reserves -= amount;
            totalReservesUSD -= usdValue;
            lifetimeWithdrawals += usdValue;
            dailyWithdrawalVolume += usdValue;

            emit ReservesWithdrawn(to, token, amount, usdValue);
            _updateReserveRatio();
            return;
        }

        // Need to close GMX positions - create pending withdrawal
        uint256 additionalNeeded = amount - availableReserves;
        uint256 withdrawalId = pendingWithdrawalCount++;

        pendingWithdrawals[withdrawalId] = PendingWithdrawal({
            user: to,
            amount: amount,
            timestamp: block.timestamp,
            associatedOrders: new bytes32[](0),
            isProcessed: false
        });

        uint256 positionsClosed = _liquidateGMXPositions(
            withdrawalId,
            additionalNeeded
        );

        if (positionsClosed == 0) {
            revert InsufficientReserves();
        }

        emit ReservesWithdrawn(to, token, amount, usdValue);
        lifetimeWithdrawals += usdValue;
        dailyWithdrawalVolume += usdValue;
        _updateReserveRatio();
    }

    // ═══════════════════════════════════════════════════════════
    // GMX POSITION MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Deploy capital to GMX positions according to basket weights
     */
    function _deployCapitalToGMX(
        uint256 depositId
    ) internal returns (uint256 deployedAmount) {
        uint256 toDeployTotal = pendingDeployment;
        if (toDeployTotal < MIN_DEPLOYMENT_AMOUNT) return 0;

        // Calculate required execution fees
        uint256 activeBasketCount = _countActiveBasket();
        uint256 totalExecutionFee = activeBasketCount * GMX_EXECUTION_FEE;

        if (msg.value < totalExecutionFee) {
            revert InsufficientExecutionFee();
        }

        // Approve GMX position manager
        usdc.safeIncreaseAllowance(address(gmxPositionManager), toDeployTotal);

        uint256 totalDeployed = 0;
        PendingDeposit storage deposit = pendingDeposits[depositId];

        // Deploy to each basket component
        for (uint256 i = 0; i < basket.length; i++) {
            CommodityAllocation storage allocation = basket[i];

            if (!allocation.isActive) continue;

            // Calculate allocation amount
            uint256 allocationAmount = (toDeployTotal *
                allocation.targetWeightBps) / BPS_DENOMINATOR;

            if (allocationAmount < MIN_DEPLOYMENT_AMOUNT / basket.length) {
                continue; // Skip if too small
            }

            // Calculate size for 1x leverage
            // GMX expects sizeDeltaUsd in 1e30 precision
            uint256 sizeDeltaUsd = allocationAmount * 1e24; // USDC (6 decimals) >> USD (30 decimals)

            try
                gmxPositionManager.openPosition{value: GMX_EXECUTION_FEE}(
                    allocation.market,
                    address(usdc), // collateralToken
                    allocationAmount,
                    sizeDeltaUsd,
                    allocation.isLong,
                    DEFAULT_SLIPPAGE_BPS
                )
            returns (bytes32 orderKey) {
                // Store pending order
                allocation.pendingOrderKey = orderKey;
                allocation.lastUpdateTime = block.timestamp;
                allocation.targetSizeUsd += sizeDeltaUsd;

                // Link order to deposit
                orderToDepositId[orderKey] = depositId;
                orderToBasketIndex[orderKey] = i;
                deposit.associatedOrders.push(orderKey);

                totalDeployed += allocationAmount;

                emit CapitalDeployed(
                    depositId,
                    i,
                    allocation.market,
                    allocationAmount,
                    sizeDeltaUsd,
                    orderKey
                );

                emit GMXOrderSubmitted(
                    orderKey,
                    depositId,
                    i,
                    true, // isIncrease
                    block.timestamp
                );
            } catch Error(string memory reason) {
                emit GMXOrderFailed(allocation.pendingOrderKey, i, reason);
                continue;
            } catch {
                emit GMXOrderFailed(
                    allocation.pendingOrderKey,
                    i,
                    "Unknown error"
                );
                continue;
            }
        }

        // Update state
        if (totalDeployed > 0) {
            pendingDeployment -= totalDeployed;
            stablecoins[address(usdc)].reserves -= totalDeployed;
        }

        return totalDeployed;
    }

    /**
     * @dev Close GMX positions to raise capital for withdrawals
     */
    function _liquidateGMXPositions(
        uint256 withdrawalId,
        uint256 amountNeeded
    ) internal returns (uint256 positionsClosed) {
        uint256 totalValue = getTotalManagedValue();
        if (totalValue == 0) return 0;

        uint256 closed = 0;
        uint256 totalRaised = 0;

        // Calculate required execution fees
        uint256 activePositionCount = _countActivePositions();
        uint256 totalExecutionFee = activePositionCount * GMX_EXECUTION_FEE;

        if (msg.value < totalExecutionFee) {
            revert InsufficientExecutionFee();
        }

        PendingWithdrawal storage withdrawal = pendingWithdrawals[withdrawalId];
        uint256 amountNeededUsd = _normalizeAmount(amountNeeded, 6);

        // Close positions proportionally
        for (
            uint256 i = 0;
            i < basket.length && totalRaised < amountNeededUsd;
            i++
        ) {
            CommodityAllocation storage allocation = basket[i];

            if (allocation.currentPositionKey == bytes32(0)) {
                continue; // No active position
            }

            // Get position value
            uint256 positionValue;
            try
                gmxPositionManager.getPositionValue(
                    allocation.currentPositionKey
                )
            returns (uint256 value) {
                positionValue = value;
            } catch {
                continue;
            }

            if (positionValue == 0) continue;

            // Calculate amount to close
            uint256 remainingNeeded = amountNeededUsd - totalRaised;
            uint256 percentToClose;

            if (remainingNeeded >= positionValue) {
                percentToClose = BPS_DENOMINATOR;
            } else {
                percentToClose =
                    (remainingNeeded * BPS_DENOMINATOR) /
                    positionValue;
                percentToClose = (percentToClose * 10500) / BPS_DENOMINATOR; // 5% buffer
                if (percentToClose > BPS_DENOMINATOR) {
                    percentToClose = BPS_DENOMINATOR;
                }
            }

            // Get position info
            IGMXV2PositionManager.PositionInfo memory posInfo;
            try
                gmxPositionManager.getPosition(allocation.currentPositionKey)
            returns (IGMXV2PositionManager.PositionInfo memory info) {
                posInfo = info;
            } catch {
                continue;
            }

            uint256 sizeToClose = (posInfo.sizeInUsd * percentToClose) /
                BPS_DENOMINATOR;
            if (sizeToClose == 0) continue;

            //  Declare closeOrderKey in proper scope
            try
                gmxPositionManager.closePosition{value: GMX_EXECUTION_FEE}(
                    allocation.currentPositionKey,
                    sizeToClose,
                    DEFAULT_SLIPPAGE_BPS
                )
            returns (bytes32 closeOrderKey) {
                closed++;

                // Link order to withdrawal
                orderToWithdrawalId[closeOrderKey] = withdrawalId;
                orderToBasketIndex[closeOrderKey] = i;
                withdrawal.associatedOrders.push(closeOrderKey);

                emit PositionClosed(
                    allocation.currentPositionKey,
                    withdrawalId,
                    i,
                    sizeToClose,
                    0
                );

                emit GMXOrderSubmitted(
                    closeOrderKey,
                    withdrawalId,
                    i,
                    false,
                    block.timestamp
                );

                if (percentToClose >= BPS_DENOMINATOR) {
                    allocation.currentPositionKey = bytes32(0);
                    allocation.targetSizeUsd = 0;
                } else {
                    allocation.targetSizeUsd = posInfo.sizeInUsd - sizeToClose;
                }

                uint256 estimatedRaised = (positionValue * percentToClose) /
                    BPS_DENOMINATOR;
                totalRaised += estimatedRaised;
            } catch Error(string memory reason) {
                emit GMXOrderFailed(bytes32(0), i, reason);
                continue;
            } catch (bytes memory lowLevelData) {
                emit GMXOrderFailed(
                    bytes32(0),
                    i,
                    lowLevelData.length > 0
                        ? string(lowLevelData)
                        : "Unknown error"
                );
                continue;
            }
        }

        // If we couldn't close enough positions, revert
        if (closed == 0) {
            revert InsufficientReserves();
        }

        return closed;
    }
    /**
     * @notice GMX callback - Order executed successfully
     * @dev Called by GMXV2PositionManager after order execution
     */
    function notifyOrderExecuted(
        bytes32 orderKey,
        bytes32 positionKey,
        bool isIncrease,
        uint256 executionPrice,
        uint256 collateralDeltaAmount,
        uint256 sizeDeltaUsd,
        int256 realizedPnl
    ) external onlyRole(GMX_CALLBACK_ROLE) nonReentrant {
        uint256 basketIndex = orderToBasketIndex[orderKey];
        require(basketIndex < basket.length, "Invalid basket index");

        CommodityAllocation storage allocation = basket[basketIndex];

        if (isIncrease) {
            // Position opened or increased
            allocation.currentPositionKey = positionKey;
            allocation.pendingOrderKey = bytes32(0);
            allocation.lastUpdateTime = block.timestamp;

            emit PositionOpened(
                positionKey,
                basketIndex,
                allocation.market,
                sizeDeltaUsd,
                collateralDeltaAmount,
                block.timestamp
            );

            // Check if this was part of a deposit
            uint256 depositId = orderToDepositId[orderKey];
            if (depositId < pendingDepositCount) {
                _processDepositCallback(depositId, orderKey, true);
            }
        } else {
            // Position closed or decreased
            emit PositionDecreased(
                positionKey,
                basketIndex,
                sizeDeltaUsd,
                collateralDeltaAmount,
                realizedPnl
            );

            // Update reserves with realized funds
            if (collateralDeltaAmount > 0) {
                stablecoins[address(usdc)].reserves += collateralDeltaAmount;
            }

            // Track yield if PnL is positive
            if (realizedPnl > 0) {
                totalYieldGenerated += uint256(realizedPnl);
            }

            // Check if this was part of a withdrawal
            uint256 withdrawalId = orderToWithdrawalId[orderKey];
            if (withdrawalId < pendingWithdrawalCount) {
                _processWithdrawalCallback(
                    withdrawalId,
                    orderKey,
                    true,
                    collateralDeltaAmount
                );
            }
        }

        emit GMXOrderExecuted(orderKey, positionKey, basketIndex, true);

        // Update cached position values
        _updatePositionValue();
        _updateReserveRatio();
    }

    /**
     * @notice GMX callback - Order failed
     */
    function notifyOrderFailed(
        bytes32 orderKey,
        string calldata reason
    ) external onlyRole(GMX_CALLBACK_ROLE) nonReentrant {
        uint256 basketIndex = orderToBasketIndex[orderKey];

        CommodityAllocation storage allocation = basket[basketIndex];
        allocation.pendingOrderKey = bytes32(0);

        emit GMXOrderFailed(orderKey, basketIndex, reason);

        // Check if this was part of a deposit
        uint256 depositId = orderToDepositId[orderKey];
        if (depositId < pendingDepositCount) {
            _processDepositCallback(depositId, orderKey, false);
        }

        // Check if this was part of a withdrawal
        uint256 withdrawalId = orderToWithdrawalId[orderKey];
        if (withdrawalId < pendingWithdrawalCount) {
            _processWithdrawalCallback(withdrawalId, orderKey, false, 0);
        }
    }

    /**
     * @dev Process deposit callback
     */
    function _processDepositCallback(
        uint256 depositId,
        bytes32 orderKey,
        bool success
    ) internal {
        PendingDeposit storage deposit = pendingDeposits[depositId];

        if (deposit.isProcessed) return;

        // Check if all associated orders are complete
        bool allComplete = true;
        for (uint256 i = 0; i < deposit.associatedOrders.length; i++) {
            bytes32 assocOrderKey = deposit.associatedOrders[i];
            uint256 idx = orderToBasketIndex[assocOrderKey];

            if (basket[idx].pendingOrderKey == assocOrderKey) {
                allComplete = false;
                break;
            }
        }

        if (allComplete) {
            deposit.isProcessed = true;
            emit DepositProcessed(
                depositId,
                deposit.user,
                deposit.amount,
                success
            );
        }
    }

    /**
     * @dev Process withdrawal callback
     */
    function _processWithdrawalCallback(
        uint256 withdrawalId,
        bytes32 orderKey,
        bool success,
        uint256 collateralReceived
    ) internal {
        PendingWithdrawal storage withdrawal = pendingWithdrawals[withdrawalId];

        if (withdrawal.isProcessed) return;

        // Check if all associated orders are complete
        bool allComplete = true;
        uint256 totalReceived = 0;

        for (uint256 i = 0; i < withdrawal.associatedOrders.length; i++) {
            bytes32 assocOrderKey = withdrawal.associatedOrders[i];
            uint256 idx = orderToBasketIndex[assocOrderKey];

            // If this is the current order, add received amount
            if (assocOrderKey == orderKey) {
                totalReceived += collateralReceived;
            }

            if (basket[idx].pendingOrderKey == assocOrderKey) {
                allComplete = false;
                break;
            }
        }

        if (allComplete) {
            withdrawal.isProcessed = true;

            // Execute final transfer to user
            if (
                success &&
                stablecoins[address(usdc)].reserves >= withdrawal.amount
            ) {
                stablecoins[address(usdc)].reserves -= withdrawal.amount;
                usdc.safeTransfer(withdrawal.user, withdrawal.amount);
            }

            emit WithdrawalProcessed(
                withdrawalId,
                withdrawal.user,
                withdrawal.amount,
                success
            );
        }
    }

    // ═══════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Get total managed value (GMX positions + reserves)
     * @dev  Excludes pendingDeployment to prevent NAV inflation
     */
    function getTotalManagedValue() public view returns (uint256 totalValue) {
        uint256 total = 0;

        // ONLY count confirmed GMX positions (not pending orders)
        for (uint256 i = 0; i < basket.length; i++) {
            bytes32 posKey = basket[i].currentPositionKey;
            if (posKey == bytes32(0)) continue; // Skip if no confirmed position

            try gmxPositionManager.getPositionValue(posKey) returns (
                uint256 value
            ) {
                total += value; // Fresh value from GMX
            } catch {
                // Fallback to cached if GMX call fails
                total += basket[i].lastKnownValue;
            }
        }

        //  Add ONLY idle reserves (NOT pendingDeployment)
        uint256 reserves = stablecoins[address(usdc)].reserves;
        total += _normalizeAmount(reserves, 6);

        return total;
    }

    //   Separate view for total including pending (for internal tracking)
    function getTotalManagedValueIncludingPending()
        external
        view
        returns (uint256)
    {
        return getTotalManagedValue() + _normalizeAmount(pendingDeployment, 6);
    }

    /**
     * @notice Get total reserves
     */
    function getTotalReserves()
        external
        view
        returns (uint256 totalUSD, uint256 reserveRatio, bool isHealthy)
    {
        totalUSD = getTotalManagedValue();
        reserveRatio = _calculateReserveRatio();
        isHealthy = reserveRatio >= MIN_RESERVE_RATIO;
    }

    /**
     * @notice Get reserve ratio (now includes GMX positions)
     */
    function getReserveRatio() external view returns (uint256 ratio) {
        return _calculateReserveRatio();
    }

    /**
     * @notice Get detailed position breakdown
     */
    function getPositionBreakdown()
        external
        view
        returns (
            string[] memory names,
            uint256[] memory positionValues,
            uint256[] memory positionSizes,
            uint256[] memory targetWeights,
            uint256[] memory actualWeights,
            uint256 idleReserves,
            uint256 totalManaged
        )
    {
        uint256 basketLength = basket.length;
        names = new string[](basketLength);
        positionValues = new uint256[](basketLength);
        positionSizes = new uint256[](basketLength);
        targetWeights = new uint256[](basketLength);
        actualWeights = new uint256[](basketLength);

        totalManaged = getTotalManagedValue();

        for (uint256 i = 0; i < basketLength; i++) {
            CommodityAllocation memory allocation = basket[i];
            names[i] = allocation.name;
            targetWeights[i] = allocation.targetWeightBps;

            bytes32 posKey = allocation.currentPositionKey;

            if (posKey != bytes32(0)) {
                try gmxPositionManager.getPosition(posKey) returns (
                    IGMXV2PositionManager.PositionInfo memory info
                ) {
                    positionValues[i] = info.collateralAmount;
                    positionSizes[i] = info.sizeInUsd;

                    if (totalManaged > 0) {
                        actualWeights[i] =
                            (info.collateralAmount * BPS_DENOMINATOR) /
                            totalManaged;
                    }
                } catch {
                    positionValues[i] = 0;
                    positionSizes[i] = 0;
                    actualWeights[i] = 0;
                }
            }
        }

        idleReserves = _normalizeAmount(stablecoins[address(usdc)].reserves, 6);

        return (
            names,
            positionValues,
            positionSizes,
            targetWeights,
            actualWeights,
            idleReserves,
            totalManaged
        );
    }

    /**
     * @notice Get idle capital ratio
     */
    function getIdleCapitalRatio() public view returns (uint256) {
        uint256 totalValue = getTotalManagedValue();
        if (totalValue == 0) return 0;

        uint256 idle = _normalizeAmount(stablecoins[address(usdc)].reserves, 6);
        return (idle * BPS_DENOMINATOR) / totalValue;
    }

    /**
     * @notice Check if capital deployment is needed
     */
    function needsDeployment() external view returns (bool, uint256) {
        if (pendingDeployment >= MIN_DEPLOYMENT_AMOUNT) {
            return (true, pendingDeployment);
        }
        return (false, 0);
    }

    /**
     * @notice Get reserve info for specific stablecoin
     */
    function getReserveInfo(
        address token
    )
        external
        view
        returns (
            uint256 reserves,
            uint256 usdValue,
            uint256 allocationBps,
            uint256 targetBps
        )
    {
        StablecoinConfig memory config = stablecoins[token];
        reserves = config.reserves;
        usdValue = _normalizeAmount(reserves, config.decimals);

        uint256 totalValue = getTotalManagedValue();
        if (totalValue > 0) {
            allocationBps = (usdValue * BPS_DENOMINATOR) / totalValue;
        }

        targetBps = config.targetAllocationBps;
    }

    /**
     * @notice Get supported stablecoins
     */
    function getSupportedStablecoins()
        external
        view
        returns (address[] memory tokens)
    {
        return supportedStablecoins;
    }

    /**
     * @notice Get reserve statistics
     */
    function getReserveStats()
        external
        view
        returns (
            uint256 totalReserves,
            uint256 lifetimeDeposits_,
            uint256 lifetimeWithdrawals_,
            uint256 lifetimeYield,
            uint256 reserveRatio,
            uint256 dailyWithdrawals
        )
    {
        return (
            getTotalManagedValue(),
            lifetimeDeposits,
            lifetimeWithdrawals,
            totalYieldGenerated,
            _calculateReserveRatio(),
            dailyWithdrawalVolume
        );
    }

    /**
     * @notice Check if withdrawal is allowed
     */
    function canWithdraw(
        uint256 usdValue
    ) external view returns (bool allowed, string memory reason) {
        // Check single withdrawal limit
        uint256 totalValue = getTotalManagedValue();
        uint256 maxSingle = (totalValue * MAX_SINGLE_WITHDRAWAL_BPS) /
            BPS_DENOMINATOR;

        if (usdValue > maxSingle) {
            return (false, "Exceeds single withdrawal limit");
        }

        // Check daily limit
        uint256 currentDaily = dailyWithdrawalVolume;
        if (block.timestamp > lastWithdrawalReset + 1 days) {
            currentDaily = 0;
        }

        uint256 maxDaily = (totalValue * MAX_DAILY_WITHDRAWAL_BPS) /
            BPS_DENOMINATOR;
        if (currentDaily + usdValue > maxDaily) {
            return (false, "Exceeds daily withdrawal limit");
        }

        // Check reserve ratio after withdrawal
        uint256 newReserves = totalValue - usdValue;
        uint256 shieldSupply = shieldVault.totalSupply();

        if (shieldSupply > 0) {
            uint256 nav = oracle.getNAVPerToken(shieldSupply);
            uint256 requiredReserves = (shieldSupply *
                nav *
                MIN_RESERVE_RATIO) / (PRECISION * BPS_DENOMINATOR);

            if (newReserves < requiredReserves) {
                return (false, "Would breach minimum reserve ratio");
            }
        }

        return (true, "");
    }

    /**
     * @notice Get basket allocation details
     */
    function getBasketAllocation(
        uint256 index
    )
        external
        view
        returns (
            address market,
            address indexToken,
            string memory name,
            uint16 targetWeightBps,
            bool isLong,
            bytes32 currentPositionKey,
            bytes32 pendingOrderKey,
            uint256 lastUpdateTime,
            uint256 targetSizeUsd,
            bool isActive
        )
    {
        require(index < basket.length, "Invalid index");
        CommodityAllocation memory allocation = basket[index];

        return (
            allocation.market,
            allocation.indexToken,
            allocation.name,
            allocation.targetWeightBps,
            allocation.isLong,
            allocation.currentPositionKey,
            allocation.pendingOrderKey,
            allocation.lastUpdateTime,
            allocation.targetSizeUsd,
            allocation.isActive
        );
    }

    /**
     * @notice Get basket length
     */
    function getBasketLength() external view returns (uint256) {
        return basket.length;
    }

    /**
     * @notice Get pending deposit info
     */
    function getPendingDeposit(
        uint256 depositId
    )
        external
        view
        returns (
            address user,
            uint256 amount,
            uint256 timestamp,
            bytes32[] memory associatedOrders,
            bool isProcessed
        )
    {
        require(depositId < pendingDepositCount, "Invalid deposit ID");
        PendingDeposit memory deposit = pendingDeposits[depositId];

        return (
            deposit.user,
            deposit.amount,
            deposit.timestamp,
            deposit.associatedOrders,
            deposit.isProcessed
        );
    }

    /**
     * @notice Get pending withdrawal info
     */
    function getPendingWithdrawal(
        uint256 withdrawalId
    )
        external
        view
        returns (
            address user,
            uint256 amount,
            uint256 timestamp,
            bytes32[] memory associatedOrders,
            bool isProcessed
        )
    {
        require(withdrawalId < pendingWithdrawalCount, "Invalid withdrawal ID");
        PendingWithdrawal memory withdrawal = pendingWithdrawals[withdrawalId];

        return (
            withdrawal.user,
            withdrawal.amount,
            withdrawal.timestamp,
            withdrawal.associatedOrders,
            withdrawal.isProcessed
        );
    }

    // ═══════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Calculate current reserve ratio (now includes GMX positions)
     */
    function _calculateReserveRatio() internal view returns (uint256) {
        uint256 shieldSupply = shieldVault.totalSupply();

        if (shieldSupply == 0) {
            return TARGET_RESERVE_RATIO;
        }

        uint256 nav = oracle.getNAVPerToken(shieldSupply);
        uint256 requiredReserves = (shieldSupply * nav) / PRECISION;

        if (requiredReserves == 0) {
            return TARGET_RESERVE_RATIO;
        }

        uint256 totalValue = getTotalManagedValue();
        return (totalValue * BPS_DENOMINATOR) / requiredReserves;
    }

    /**
     * @dev Update total reserves (includes GMX position values)
     */
    function _updateTotalReserves() internal {
        totalReservesUSD = getTotalManagedValue();
    }

    /**
     * @dev Update and emit reserve ratio
     */
    function _updateReserveRatio() internal {
        uint256 ratio = _calculateReserveRatio();
        uint256 supply = shieldVault.totalSupply();

        emit ReserveRatioUpdated(ratio, totalReservesUSD, supply);
    }

    /**
     * @dev Update cached position values
     */
    function _updatePositionValue() internal {
        uint256 gmxValue = 0;
        uint256 reserveValue = _normalizeAmount(
            stablecoins[address(usdc)].reserves,
            6
        );

        for (uint256 i = 0; i < basket.length; i++) {
            bytes32 posKey = basket[i].currentPositionKey;
            if (posKey != bytes32(0)) {
                try gmxPositionManager.getPositionValue(posKey) returns (
                    uint256 value
                ) {
                    gmxValue += value;
                } catch {
                    continue;
                }
            }
        }

        totalGMXPositionValue = gmxValue;
        totalReservesUSD = gmxValue + reserveValue;
        lastPositionValueUpdate = block.timestamp;

        emit PositionValueUpdated(
            totalReservesUSD,
            gmxValue,
            reserveValue,
            block.timestamp
        );
    }

    /**
     * @dev Normalize amount to 18 decimals
     */
    function _normalizeAmount(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount * (10 ** (18 - decimals));
        } else {
            return amount / (10 ** (decimals - 18));
        }
    }

    /**
     * @dev Convert amount between different decimals
     */
    function _convertAmount(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        }

        uint256 normalized = _normalizeAmount(amount, fromDecimals);
        return _denormalizeAmount(normalized, toDecimals);
    }

    /**
     * @dev Denormalize amount from 18 decimals
     */
    function _denormalizeAmount(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount / (10 ** (18 - decimals));
        } else {
            return amount * (10 ** (decimals - 18));
        }
    }

    /**
     * @dev Check withdrawal limits (circuit breaker)
     */
    function _checkWithdrawalLimits(uint256 usdValue) internal {
        // Reset daily counter if needed
        if (block.timestamp > lastWithdrawalReset + 1 days) {
            dailyWithdrawalVolume = 0;
            lastWithdrawalReset = block.timestamp;
        }

        uint256 totalValue = getTotalManagedValue();

        // Check single withdrawal limit
        uint256 maxSingle = (totalValue * MAX_SINGLE_WITHDRAWAL_BPS) /
            BPS_DENOMINATOR;
        if (usdValue > maxSingle) {
            revert ExceedsSingleWithdrawalLimit();
        }

        // Check daily withdrawal limit
        uint256 maxDaily = (totalValue * MAX_DAILY_WITHDRAWAL_BPS) /
            BPS_DENOMINATOR;
        if (dailyWithdrawalVolume + usdValue > maxDaily) {
            revert ExceedsDailyWithdrawalLimit();
        }
    }

    /**
     * @dev Check idle capital ratio
     */
    function _checkIdleCapitalRatio() internal {
        uint256 idleRatio = getIdleCapitalRatio();

        if (idleRatio > MAX_IDLE_CAPITAL_BPS) {
            uint256 totalValue = getTotalManagedValue();
            uint256 idleAmount = _normalizeAmount(
                stablecoins[address(usdc)].reserves,
                6
            );

            emit IdleCapitalWarning(idleAmount, totalValue, idleRatio);
        }
    }

    /**
     * @dev Count active basket allocations
     */
    function _countActiveBasket() internal view returns (uint256 count) {
        for (uint256 i = 0; i < basket.length; i++) {
            if (basket[i].isActive) count++;
        }
    }

    /**
     * @dev Count active GMX positions
     */
    function _countActivePositions() internal view returns (uint256 count) {
        for (uint256 i = 0; i < basket.length; i++) {
            if (basket[i].currentPositionKey != bytes32(0)) count++;
        }
    }

    /**
     * @dev Initialize default basket (MUST UPDATE WITH REAL ADDRESSES!)
     */
    function _initializeDefaultBasket() internal {
        // Clear any existing allocations
        delete basket;
        totalWeightBps = 0;

        // 20% Gold (XAU/USD)
        basket.push(
            CommodityAllocation({
                market: address(0), // TODO: Set actual GMX XAU/USD market
                indexToken: address(0),
                name: "Gold",
                targetWeightBps: 2000,
                isLong: true,
                currentPositionKey: bytes32(0),
                pendingOrderKey: bytes32(0),
                lastUpdateTime: 0,
                targetSizeUsd: 0,
                isActive: true,
                lastKnownValue: 0
            })
        );
        totalWeightBps += 2000;

        // 15% Oil (WTI/USD)
        basket.push(
            CommodityAllocation({
                market: address(0),
                indexToken: address(0),
                name: "Oil",
                targetWeightBps: 1500,
                isLong: true,
                currentPositionKey: bytes32(0),
                pendingOrderKey: bytes32(0),
                lastUpdateTime: 0,
                targetSizeUsd: 0,
                isActive: true,
                lastKnownValue: 0
            })
        );
        totalWeightBps += 1500;

        // 25% EUR/USD
        basket.push(
            CommodityAllocation({
                market: address(0),
                indexToken: address(0),
                name: "EUR/USD",
                targetWeightBps: 2500,
                isLong: true,
                currentPositionKey: bytes32(0),
                pendingOrderKey: bytes32(0),
                lastUpdateTime: 0,
                targetSizeUsd: 0,
                isActive: true,
                lastKnownValue: 0
            })
        );
        totalWeightBps += 2500;

        // 15% JPY/USD
        basket.push(
            CommodityAllocation({
                market: address(0),
                indexToken: address(0),
                name: "JPY/USD",
                targetWeightBps: 1500,
                isLong: true,
                currentPositionKey: bytes32(0),
                pendingOrderKey: bytes32(0),
                lastUpdateTime: 0,
                targetSizeUsd: 0,
                isActive: true,
                lastKnownValue: 0
            })
        );
        totalWeightBps += 1500;

        // 10% Wheat 
        basket.push(
            CommodityAllocation({
                market: address(0),
                indexToken: address(0),
                name: "Wheat",
                targetWeightBps: 1000,
                isLong: true,
                currentPositionKey: bytes32(0),
                pendingOrderKey: bytes32(0),
                lastUpdateTime: 0,
                targetSizeUsd: 0,
                isActive: true, 
                lastKnownValue: 0
            })
        );
        totalWeightBps += 1000;

        // 15% Copper 
        basket.push(
            CommodityAllocation({
                market: address(0),
                indexToken: address(0),
                name: "Copper",
                targetWeightBps: 1500,
                isLong: true,
                currentPositionKey: bytes32(0),
                pendingOrderKey: bytes32(0),
                lastUpdateTime: 0,
                targetSizeUsd: 0,
                isActive: true, 
                lastKnownValue: 0
            })
        );
        totalWeightBps += 1500;

        //  Validate total active weights = 100%
        uint256 activeWeights = 0;
        for (uint256 i = 0; i < basket.length; i++) {
            if (basket[i].isActive) {
                activeWeights += basket[i].targetWeightBps;
            }
        }

        require(
            activeWeights == BPS_DENOMINATOR,
            "Active weights must sum to 100%"
        );
    }

    // ═══════════════════════════════════════════════════════════
    // REBALANCING OPERATIONS 
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Rebalance GMX positions to match target weights
     * @dev Replaces old stablecoin rebalancing with position rebalancing
     */
    function rebalancePositions()
        external
        payable
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        whenNotPaused
    {
        // Check cooldown
        if (block.timestamp < lastRebalanceTime + rebalanceCooldown) {
            revert CooldownActive();
        }

        if (rebalanceInProgress) revert RebalanceInProgress();

        rebalanceInProgress = true;

        uint256 totalValue = getTotalManagedValue();
        if (totalValue == 0) {
            rebalanceInProgress = false;
            return;
        }

        // Calculate current weights and deviations
        for (uint256 i = 0; i < basket.length; i++) {
            CommodityAllocation storage allocation = basket[i];

            if (!allocation.isActive) continue;

            uint256 currentValue = 0;
            if (allocation.currentPositionKey != bytes32(0)) {
                try
                    gmxPositionManager.getPositionValue(
                        allocation.currentPositionKey
                    )
                returns (uint256 value) {
                    currentValue = value;
                } catch {
                    continue;
                }
            }

            uint256 currentWeightBps = (currentValue * BPS_DENOMINATOR) /
                totalValue;
            uint256 targetWeightBps = allocation.targetWeightBps;

            // Calculate deviation
            int256 deviationBps = int256(targetWeightBps) -
                int256(currentWeightBps);

            // Rebalance if deviation > 5%
            if (deviationBps > 500 || deviationBps < -500) {
                uint256 targetValue = (totalValue * targetWeightBps) /
                    BPS_DENOMINATOR;

                if (deviationBps > 0) {
                    // Need to increase position
                    uint256 increaseAmount = targetValue - currentValue;
                    _increasePosition(i, increaseAmount);
                } else {
                    // Need to decrease position
                    uint256 decreaseAmount = currentValue - targetValue;
                    _decreasePosition(i, decreaseAmount);
                }
            }
        }

        lastRebalanceTime = block.timestamp;
        rebalanceInProgress = false;

        emit RebalanceExecuted(address(0), address(0), 0, block.timestamp);
    }

    /**
     * @dev Increase position size
     */
    function _increasePosition(
        uint256 basketIndex,
        uint256 increaseAmountUsd
    ) internal {
        CommodityAllocation storage allocation = basket[basketIndex];

        // Convert USD amount to collateral amount (USDC)
        uint256 collateralAmount = increaseAmountUsd / 1e12; // 18 decimals >> 6 decimals

        // Check if we have enough reserves
        if (stablecoins[address(usdc)].reserves < collateralAmount) {
            return; // Skip if insufficient reserves
        }

        uint256 sizeDeltaUsd = increaseAmountUsd * 1e12; // 18 decimals >> 30 decimals

        usdc.safeIncreaseAllowance(
            address(gmxPositionManager),
            collateralAmount
        );

        try
            gmxPositionManager.openPosition{value: GMX_EXECUTION_FEE}(
                allocation.market,
                address(usdc),
                collateralAmount,
                sizeDeltaUsd,
                allocation.isLong,
                DEFAULT_SLIPPAGE_BPS
            )
        returns (bytes32 orderKey) {
            allocation.pendingOrderKey = orderKey;
            allocation.lastUpdateTime = block.timestamp;

            stablecoins[address(usdc)].reserves -= collateralAmount;

            emit PositionIncreased(
                allocation.currentPositionKey,
                basketIndex,
                sizeDeltaUsd,
                collateralAmount
            );
        } catch {
            // Revert allowance on failure
            usdc.safeDecreaseAllowance(
                address(gmxPositionManager),
                collateralAmount
            );
        }
    }

    /**
     * @dev Decrease position size
     */
    function _decreasePosition(
        uint256 basketIndex,
        uint256 decreaseAmountUsd
    ) internal {
        CommodityAllocation storage allocation = basket[basketIndex];

        if (allocation.currentPositionKey == bytes32(0)) {
            return; // No position to decrease
        }

        uint256 sizeDeltaUsd = decreaseAmountUsd * 1e12; // 18 decimals >> 30 decimals

        try
            gmxPositionManager.closePosition{value: GMX_EXECUTION_FEE}(
                allocation.currentPositionKey,
                sizeDeltaUsd,
                DEFAULT_SLIPPAGE_BPS
            )
        returns (bytes32 orderKey) {
            allocation.pendingOrderKey = orderKey;
            allocation.lastUpdateTime = block.timestamp;

            emit PositionDecreased(
                allocation.currentPositionKey,
                basketIndex,
                sizeDeltaUsd,
                0, // Collateral delta calculated in callback
                0 // PnL calculated in callback
            );
        } catch {
            // Continue on failure
        }
    }

    // ═══════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS 
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Add new basket allocation
     */
    function addBasketAllocation(
        address market,
        address indexToken,
        string calldata name,
        uint16 targetWeightBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (market == address(0)) revert ZeroAddress();
        if (indexToken == address(0)) revert ZeroAddress();
        if (targetWeightBps == 0) revert InvalidAllocation();

        // Validate total weights don't exceed 100%
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < basket.length; i++) {
            if (basket[i].isActive) {
                totalWeight += basket[i].targetWeightBps;
            }
        }

        if (totalWeight + targetWeightBps > BPS_DENOMINATOR) {
            revert InvalidAllocation();
        }

        uint256 newIndex = basket.length;

        basket.push(
            CommodityAllocation({
                market: market,
                indexToken: indexToken,
                name: name,
                targetWeightBps: targetWeightBps,
                isLong: true,
                currentPositionKey: bytes32(0),
                pendingOrderKey: bytes32(0),
                lastUpdateTime: 0,
                targetSizeUsd: 0,
                isActive: true,
                lastKnownValue: 0
            })
        );

        emit BasketAllocationAdded(newIndex, market, name, targetWeightBps);
    }

    /**
     * @notice Update basket allocation weight
     */
    function updateBasketWeight(
        uint256 basketIndex,
        uint16 newWeightBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(basketIndex < basket.length, "Invalid index");

        CommodityAllocation storage allocation = basket[basketIndex];

        // Validate total weights
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < basket.length; i++) {
            if (i == basketIndex) {
                totalWeight += newWeightBps;
            } else if (basket[i].isActive) {
                totalWeight += basket[i].targetWeightBps;
            }
        }

        if (totalWeight > BPS_DENOMINATOR) {
            revert InvalidAllocation();
        }

        uint16 oldWeight = allocation.targetWeightBps;
        allocation.targetWeightBps = newWeightBps;

        emit BasketAllocationUpdated(basketIndex, oldWeight, newWeightBps);
    }

    /**
     * @notice Activate/deactivate basket allocation
     */
    function setBasketAllocationActive(
        uint256 basketIndex,
        bool active
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(basketIndex < basket.length, "Invalid index");

        CommodityAllocation storage allocation = basket[basketIndex];

        // If deactivating, ensure no open position
        if (!active && allocation.currentPositionKey != bytes32(0)) {
            revert FundsStillAllocated();
        }

        allocation.isActive = active;
    }

    /**
     * @notice Update emergency buffer target
     */
    function setEmergencyBufferTarget(
        uint256 newBufferBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBufferBps > 2000) revert InvalidAllocation(); // Max 20%

        uint256 oldBufferBps = targetEmergencyBufferBps;
        targetEmergencyBufferBps = newBufferBps;

        emit EmergencyBufferUpdated(oldBufferBps, newBufferBps);
    }

    /**
     * @notice Force deploy pending capital (manual trigger)
     */
    function forceDeployCapital()
        external
        payable
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        whenNotPaused
    {
        require(pendingDeployment >= MIN_DEPLOYMENT_AMOUNT, "Below minimum");

        uint256 depositId = pendingDepositCount++;
        pendingDeposits[depositId] = PendingDeposit({
            user: msg.sender,
            amount: pendingDeployment,
            timestamp: block.timestamp,
            associatedOrders: new bytes32[](0),
            isProcessed: false
        });

        _deployCapitalToGMX(depositId);
    }

    /**
     * @notice Update rebalance cooldown
     */
    function setRebalanceCooldown(
        uint256 cooldown
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            cooldown < MIN_REBALANCE_COOLDOWN ||
            cooldown > MAX_REBALANCE_COOLDOWN
        ) {
            revert InvalidCooldown();
        }

        uint256 oldCooldown = rebalanceCooldown;
        rebalanceCooldown = cooldown;

        emit RebalanceCooldownUpdated(oldCooldown, cooldown);
    }

    /**
     * @notice Add supported stablecoin
     */
    function addStablecoin(
        address token,
        uint8 decimals,
        uint256 targetAllocationBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (decimals == 0 || decimals > 18) revert InvalidDecimals();
        if (targetAllocationBps > BPS_DENOMINATOR) revert InvalidAllocation();
        if (stablecoins[token].isActive) revert StablecoinAlreadyAdded();

        stablecoins[token] = StablecoinConfig({
            token: token,
            decimals: decimals,
            isActive: true,
            reserves: 0,
            targetAllocationBps: targetAllocationBps
        });

        supportedStablecoins.push(token);

        emit StablecoinAdded(token, decimals, targetAllocationBps);
    }

    /**
     * @notice Remove supported stablecoin
     */
    function removeStablecoin(
        address token
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StablecoinConfig storage config = stablecoins[token];
        if (!config.isActive) revert NotActive();
        if (config.reserves > 0) revert ReservesNotZero();

        config.isActive = false;

        // Remove from array
        for (uint256 i = 0; i < supportedStablecoins.length; i++) {
            if (supportedStablecoins[i] == token) {
                supportedStablecoins[i] = supportedStablecoins[
                    supportedStablecoins.length - 1
                ];
                supportedStablecoins.pop();
                break;
            }
        }

        emit StablecoinRemoved(token);
    }

    /**
     * @notice Update target allocation for stablecoin
     */
    function updateTargetAllocation(
        address token,
        uint256 targetAllocationBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (targetAllocationBps > BPS_DENOMINATOR) revert InvalidAllocation();

        StablecoinConfig storage config = stablecoins[token];
        if (!config.isActive) revert NotActive();

        uint256 oldAllocation = config.targetAllocationBps;
        config.targetAllocationBps = targetAllocationBps;

        emit TargetAllocationUpdated(token, oldAllocation, targetAllocationBps);
    }

    /**
     * @notice Emergency pause
     */
    function emergencyPause(
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) {
        _pause();
        emit EmergencyShutdown(msg.sender, reason);
    }

    /**
     * @notice Unpause
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdraw (only when paused)
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient,
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) {
        if (!paused()) revert MustBePaused();
        if (recipient == address(0)) revert InvalidRecipient();

        StablecoinConfig storage config = stablecoins[token];
        if (config.reserves < amount) revert InsufficientReserves();

        // Update state
        config.reserves -= amount;
        uint256 usdValue = _normalizeAmount(amount, config.decimals);
        totalReservesUSD -= usdValue;

        // Transfer
        IERC20(token).safeTransfer(recipient, amount);

        emit EmergencyWithdrawal(recipient, token, amount, reason);
    }

    /**
     * @notice Recover stuck tokens
     */
    function recoverStuckTokens(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient();
        if (stablecoins[token].isActive) revert CannotRecoverManagedToken();

        IERC20(token).safeTransfer(recipient, amount);

        emit TokensRecovered(token, recipient, amount);
    }

    /**
     * @notice Emergency close all positions (circuit breaker)
     */
    function emergencyCloseAllPositions()
        external
        payable
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        if (!paused()) revert MustBePaused();

        uint256 positionCount = _countActivePositions();
        require(
            msg.value >= positionCount * GMX_EXECUTION_FEE,
            "Insufficient execution fee"
        );

        for (uint256 i = 0; i < basket.length; i++) {
            CommodityAllocation storage allocation = basket[i];

            if (allocation.currentPositionKey == bytes32(0)) continue;

            IGMXV2PositionManager.PositionInfo memory posInfo;
            try
                gmxPositionManager.getPosition(allocation.currentPositionKey)
            returns (IGMXV2PositionManager.PositionInfo memory info) {
                posInfo = info;
            } catch {
                continue;
            }

            // Close 100% of position
            try
                gmxPositionManager.closePosition{value: GMX_EXECUTION_FEE}(
                    allocation.currentPositionKey,
                    posInfo.sizeInUsd, // Close entire position
                    DEFAULT_SLIPPAGE_BPS
                )
            returns (bytes32 closeOrderKey) {
                allocation.pendingOrderKey = closeOrderKey;
                allocation.currentPositionKey = bytes32(0);
                allocation.targetSizeUsd = 0;

                emit PositionClosed(
                    allocation.currentPositionKey,
                    0, // No withdrawal ID for emergency
                    i,
                    posInfo.sizeInUsd,
                    0
                );
            } catch {
                continue;
            }
        }
    }

    /**
     * @notice Receive ETH for GMX execution fees
     */
    receive() external payable {}

    /**
     * @notice Withdraw excess ETH
     */
    function withdrawETH(
        address recipient,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient();

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }
}
