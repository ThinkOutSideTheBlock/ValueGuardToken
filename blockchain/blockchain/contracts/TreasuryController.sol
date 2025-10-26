// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./interfaces/IErrors.sol";
import "./interfaces/IBasketOracle.sol";

// ═══════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════

error OptionNotActive();
error OptionExpired();
error OptionNotExpired();
error NotOptionOwner();
error OptionNotInTheMoney();
error PayoffOverflow();
error PremiumTooHigh();
error InvalidDuration();
error InvalidStrike();
error InvalidNotional();
error TWAPWindowTooLarge();
error NoBaseFeeData();
error InsufficientTreasuryBalance();
error DailyLimitExceeded();
error InvalidRecipient();

// ═══════════════════════════════════════════════════════════
// TREASURY CONTROLLER CONTRACT
// ═══════════════════════════════════════════════════════════

contract TreasuryController is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;

    // ─── Role Constants ─────────────────────────────────────

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant FEE_COLLECTOR_ROLE =
        keccak256("FEE_COLLECTOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ─── Protocol Constants ─────────────────────────────────

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant PRECISION = 1e18;

    // Gas option parameters
    uint256 public constant MAX_OPTION_DURATION = 7 days;
    uint256 public constant MIN_OPTION_DURATION = 1 hours;
    uint256 public constant MAX_STRIKE_PRICE = 1000 gwei; // 1000 gwei max
    uint256 public constant MAX_NOTIONAL = 10_000_000; // 10M gas units max
    uint256 public constant MAX_PAYOFF_MULTIPLIER = 10; // 10x premium max
    uint256 public constant MAX_PREMIUM_MULTIPLIER = 10; // 10x notional value max
    uint256 public minTWAPSnapshots = 12; // Configurable minimum TWAP data
    uint256 public maxSpotDeviationBps = 3000; // 30% max deviation
    // Base fee tracking
    uint256 public constant MAX_BASEFEE_SNAPSHOTS = 288; // 24 hours at 5min intervals
    uint256 public constant BASEFEE_SNAPSHOT_INTERVAL = 5 minutes;

    // Pull payment gas limit (PRESERVED FIX: M-8)
    uint256 public constant PAYOUT_GAS_LIMIT = 100000;

    // ─── Immutables ─────────────────────────────────────────

    IBasketOracle public immutable oracle;
    IERC20 public immutable shieldToken; // SHIELD token (for fee collection)

    // ─── State Variables ────────────────────────────────────

    // Treasury balances
    uint256 public treasuryShieldBalance; // SHIELD tokens collected as fees
    uint256 public treasuryETHBalance; // ETH for gas option payouts

    // Fee tracking
    uint256 public totalFeesCollected; // Total SHIELD fees (USD value)
    uint256 public lifetimeMintFees; // From mintShield()
    uint256 public lifetimeRedeemFees; // From redeemShield()
    uint256 public lifetimeManagementFees; // Annual management fee

    // Gas options state
    struct GasOption {
        uint256 id;
        address buyer;
        uint256 strikePrice; // In wei (not gwei for precision)
        uint256 notionalAmount; // Gas units covered
        uint256 premium; // In wei
        uint256 expiryTimestamp;
        uint256 createdAt;
        bool isCall; // true = call, false = put
        bool isExercised;
        bool isActive;
    }

    uint256 public optionIdCounter;
    mapping(uint256 => GasOption) public gasOptions;
    mapping(address => uint256[]) public userOptions;

    // Options market parameters
    uint256 public impliedVolatility; // Scaled by 100 (80 = 80%)
    uint256 public minPremiumBps; // Minimum premium as % of notional
    uint256 public totalOptionsVolume; // Lifetime premium collected
    uint256 public totalPayouts; // Lifetime payouts made

    //  Pull payment pattern
    mapping(address => uint256) public pendingPayouts;
    uint256 public totalPendingPayouts;

    // Base fee tracking for TWAP
    struct BaseFeeSnapshot {
        uint128 baseFee;
        uint128 timestamp;
    }

    uint256 private baseFeeHead; // Circular buffer head
    BaseFeeSnapshot[MAX_BASEFEE_SNAPSHOTS] private baseFeeSnapshots;
    uint256 public snapshotCount;
    uint256 public lastSnapshotTime;

    // Circuit breakers
    uint256 public maxDailyOptionsVolume;
    uint256 public dailyOptionsVolume;
    uint256 public lastOptionsReset;

    // ─── Events ─────────────────────────────────────────────

    event FeeCollected(
        address indexed from,
        uint256 shieldAmount,
        uint256 usdValue,
        string feeType
    );

    event GasOptionIssued(
        uint256 indexed optionId,
        address indexed buyer,
        uint256 strikePrice,
        uint256 notionalAmount,
        uint256 premium,
        bool isCall
    );

    event GasOptionExercised(
        uint256 indexed optionId,
        address indexed buyer,
        uint256 payoff,
        uint256 gasPriceTWAP
    );

    event GasOptionExpired(uint256 indexed optionId);

    event PayoutWithdrawn(address indexed user, uint256 amount);

    event BaseFeeRecorded(uint256 baseFee, uint256 timestamp);

    event TreasuryWithdrawal(
        address indexed recipient,
        address indexed token,
        uint256 amount
    );

    event EmergencyShutdown(address indexed by, string reason);

    //  Warning event for volatility monitoring
    event GasPriceVolatilityWarning(
        uint256 indexed optionId,
        uint256 spotPrice,
        uint256 twapPrice
    );

    // ─── Constructor ────────────────────────────────────────

    /**
     * @notice Initialize treasury controller
     * @param _oracle BasketOracle address
     * @param _shieldToken SHIELD token address
     * @param _admin Primary admin address
     */
    constructor(address _oracle, address _shieldToken, address _admin) {
        if (_oracle == address(0)) revert ZeroAddress();
        if (_shieldToken == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        oracle = IBasketOracle(_oracle);
        shieldToken = IERC20(_shieldToken);

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);
        _grantRole(FEE_COLLECTOR_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);

        // Initialize gas options parameters
        impliedVolatility = 80; // 80% IV
        minPremiumBps = 10; // 0.1% minimum premium
        maxDailyOptionsVolume = 1000 ether; // 1000 ETH daily limit

        // Initialize circular buffer with first snapshot
        baseFeeSnapshots[0] = BaseFeeSnapshot({
            baseFee: uint128(block.basefee),
            timestamp: uint128(block.timestamp)
        });
        baseFeeHead = 1;
        snapshotCount = 1;
        lastSnapshotTime = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════
    // FEE COLLECTION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Collect fees from ShieldVault
     * @param amount Amount of SHIELD tokens received as fees
     * @param feeType Type of fee ("mint", "redeem", "management")
     * @dev Called by ShieldVault contract
     */
    function notifyFeeCollection(
        uint256 amount,
        string calldata feeType
    ) external onlyRole(FEE_COLLECTOR_ROLE) {
        if (amount == 0) return;

        // Transfer SHIELD tokens from caller
        shieldToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update balances
        treasuryShieldBalance += amount;

        // Get USD value from oracle
        uint256 nav = oracle.getNAVPerToken(shieldToken.totalSupply());
        uint256 usdValue = (amount * nav) / PRECISION;

        totalFeesCollected += usdValue;

        // Track by fee type
        bytes32 feeTypeHash = keccak256(bytes(feeType));
        if (feeTypeHash == keccak256("mint")) {
            lifetimeMintFees += usdValue;
        } else if (feeTypeHash == keccak256("redeem")) {
            lifetimeRedeemFees += usdValue;
        } else if (feeTypeHash == keccak256("management")) {
            lifetimeManagementFees += usdValue;
        }

        emit FeeCollected(msg.sender, amount, usdValue, feeType);
    }

    /**
     * @notice Deposit ETH to treasury for gas option payouts
     * @dev Anyone can donate ETH to support options market
     */
    function depositETHForOptions() external payable {
        require(msg.value > 0, "No ETH sent");
        treasuryETHBalance += msg.value;
    }

    // ═══════════════════════════════════════════════════════════
    // GAS OPTIONS MARKET
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Issue gas price option (call or put)
     * @param strikePrice Strike price in wei
     * @param notionalAmount Gas units covered
     * @param duration Option duration in seconds
     * @param isCall True for call option, false for put option
     * @return optionId ID of created option
     *
     */
    function issueGasOption(
        uint256 strikePrice,
        uint256 notionalAmount,
        uint256 duration,
        bool isCall
    ) external payable nonReentrant whenNotPaused returns (uint256 optionId) {
        // ─── VALIDATION ─────────────────────────────────────────

        if (strikePrice == 0 || strikePrice > MAX_STRIKE_PRICE) {
            revert InvalidStrike();
        }

        if (notionalAmount == 0 || notionalAmount > MAX_NOTIONAL) {
            revert InvalidNotional();
        }

        if (duration < MIN_OPTION_DURATION || duration > MAX_OPTION_DURATION) {
            revert InvalidDuration();
        }

        _checkDailyOptionsLimit(msg.value);

        // ─── PREMIUM CALCULATION ────────────────────────────────

        uint256 premium = _calculateOptionPremium(
            strikePrice,
            notionalAmount,
            duration,
            isCall
        );

        if (msg.value < premium) revert InvalidAmount();

        // ─── EFFECTS ────────────────────────────────────────────

        optionId = ++optionIdCounter;

        gasOptions[optionId] = GasOption({
            id: optionId,
            buyer: msg.sender,
            strikePrice: strikePrice,
            notionalAmount: notionalAmount,
            premium: premium,
            expiryTimestamp: block.timestamp + duration,
            createdAt: block.timestamp,
            isCall: isCall,
            isExercised: false,
            isActive: true
        });

        userOptions[msg.sender].push(optionId);

        totalOptionsVolume += premium;
        dailyOptionsVolume += premium;
        treasuryETHBalance += premium;

        // ─── INTERACTIONS ───────────────────────────────────────

        // Refund excess ETH
        if (msg.value > premium) {
            uint256 refund = msg.value - premium;
            (bool success, ) = msg.sender.call{value: refund}("");
            if (!success) revert TransferFailed();
        }

        emit GasOptionIssued(
            optionId,
            msg.sender,
            strikePrice,
            notionalAmount,
            premium,
            isCall
        );

        return optionId;
    }

    /**
     * @notice Exercise gas option if profitable
     * @param optionId Option ID to exercise
     *
     * @dev Added spot price deviation check
     */
    function exerciseGasOption(
        uint256 optionId
    ) external nonReentrant whenNotPaused {
        GasOption storage option = gasOptions[optionId];

        // VALIDATION
        if (!option.isActive) revert OptionNotActive();
        if (option.buyer != msg.sender) revert NotOptionOwner();
        if (block.timestamp > option.expiryTimestamp) revert OptionExpired();
        if (option.isExercised) revert OptionNotActive();

        // GAS PRICE CALCULATION
        // Require minimum data for TWAP
        if (snapshotCount < 12) revert NoBaseFeeData(); // 1 hour minimum

        // Use 1-hour TWAP (manipulation resistant)
        uint256 twapGasPrice = _getBaseFeeTWAP(1 hours);

        //  Reject exercise if spot price deviates too much
        uint256 spotGasPrice = block.basefee;

        // Allow 30% deviation max (configurable)
        uint256 maxDeviation = (twapGasPrice * 30) / 100;

        if (
            spotGasPrice > twapGasPrice + maxDeviation ||
            spotGasPrice + maxDeviation < twapGasPrice
        ) {
            // Emit warning and revert (prevent manipulation during volatile periods)
            emit GasPriceVolatilityWarning(
                optionId,
                spotGasPrice,
                twapGasPrice
            );
            revert("Gas price too volatile");
        }

        // CALCULATE PAYOFF
        uint256 payoff = 0;

        if (option.isCall) {
            // Call option: profit if gas price above strike
            if (twapGasPrice > option.strikePrice) {
                uint256 diff = twapGasPrice - option.strikePrice;

                // Check overflow
                if (diff > type(uint256).max / option.notionalAmount) {
                    revert PayoffOverflow();
                }

                payoff = diff * option.notionalAmount;
            }
        } else {
            // Put option: profit if gas price below strike
            if (option.strikePrice > twapGasPrice) {
                uint256 diff = option.strikePrice - twapGasPrice;

                // Check overflow
                if (diff > type(uint256).max / option.notionalAmount) {
                    revert PayoffOverflow();
                }

                payoff = diff * option.notionalAmount;
            }
        }

        if (payoff == 0) revert OptionNotInTheMoney();

        // APPLY CAPS
        // Cap at 10x premium
        uint256 maxPayoff = option.premium * MAX_PAYOFF_MULTIPLIER;
        if (payoff > maxPayoff) {
            payoff = maxPayoff;
        }

        // Check treasury has funds
        if (treasuryETHBalance < payoff) {
            revert InsufficientTreasuryBalance();
        }

        // EFFECTS (Pull payment pattern)
        option.isExercised = true;
        option.isActive = false;
        totalPayouts += payoff;
        treasuryETHBalance -= payoff;

        // Pull payment pattern
        pendingPayouts[msg.sender] += payoff;
        totalPendingPayouts += payoff;

        emit GasOptionExercised(optionId, msg.sender, payoff, twapGasPrice);
    }
    /**
     * @notice Withdraw accumulated payouts
     * @dev Pull payment pattern with increased gas limit
     */
    function withdrawPayout() external nonReentrant {
        uint256 amount = pendingPayouts[msg.sender];
        require(amount > 0, "No payout");

        // Effects before interaction
        pendingPayouts[msg.sender] = 0;
        totalPendingPayouts -= amount;

        //  Increased gas limit to 100k
        (bool success, ) = msg.sender.call{
            value: amount,
            gas: PAYOUT_GAS_LIMIT
        }("");

        if (!success) {
            // Revert effects on failure
            pendingPayouts[msg.sender] = amount;
            totalPendingPayouts += amount;
            revert TransferFailed();
        }

        emit PayoutWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Batch withdraw payouts for multiple users
     * @dev  Help users claim efficiently
     */
    function batchWithdrawPayouts(
        address[] calldata users
    ) external nonReentrant {
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 amount = pendingPayouts[user];

            if (amount > 0) {
                pendingPayouts[user] = 0;
                totalPendingPayouts -= amount;

                (bool success, ) = user.call{
                    value: amount,
                    gas: PAYOUT_GAS_LIMIT
                }("");

                if (!success) {
                    // Revert effects for this user only
                    pendingPayouts[user] = amount;
                    totalPendingPayouts += amount;
                } else {
                    emit PayoutWithdrawn(user, amount);
                }
            }
        }
    }

    /**
     * @notice Expire worthless option
     * @param optionId Option ID to expire
     */
    function expireOption(uint256 optionId) external {
        GasOption storage option = gasOptions[optionId];

        if (!option.isActive) revert OptionNotActive();
        if (block.timestamp <= option.expiryTimestamp) {
            revert OptionNotExpired();
        }

        option.isActive = false;

        emit GasOptionExpired(optionId);
    }

    // ═══════════════════════════════════════════════════════════
    // BASE FEE TRACKING
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Record current base fee for TWAP calculation
     * @dev Added overflow protection for snapshotCount
     */
    function recordBaseFee() external onlyRole(KEEPER_ROLE) {
        // Revert if called too soon
        require(
            block.timestamp >= lastSnapshotTime + BASEFEE_SNAPSHOT_INTERVAL,
            "Snapshot interval not elapsed"
        );

        //  Explicit bounds check before increment
        require(snapshotCount <= MAX_BASEFEE_SNAPSHOTS, "Buffer corrupted");

        // Write to circular buffer
        baseFeeSnapshots[baseFeeHead] = BaseFeeSnapshot({
            baseFee: uint128(block.basefee),
            timestamp: uint128(block.timestamp)
        });

        //  Safe modulo operation
        unchecked {
            // baseFeeHead is guaranteed to be < MAX_BASEFEE_SNAPSHOTS after modulo
            baseFeeHead = (baseFeeHead + 1) % MAX_BASEFEE_SNAPSHOTS;
        }

        //  Prevent snapshotCount from exceeding maximum
        if (snapshotCount < MAX_BASEFEE_SNAPSHOTS) {
            unchecked {
                snapshotCount++; // Safe because of condition above
            }
        }
        // If snapshotCount == MAX_BASEFEE_SNAPSHOTS, buffer is full, don't increment

        lastSnapshotTime = block.timestamp;

        emit BaseFeeRecorded(block.basefee, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Calculate option premium using simplified Black-Scholes
     * @dev  Removed unnecessary overflow checks and fixed cap logic
     */
    function _calculateOptionPremium(
        uint256 strikePrice,
        uint256 notionalAmount,
        uint256 duration,
        bool isCall
    ) internal view returns (uint256) {
        //  Require minimum TWAP data for options
        uint256 spotPrice;

        if (snapshotCount >= 12) {
            // Use 1-hour TWAP (manipulation resistant)
            spotPrice = _getBaseFeeTWAP(1 hours);
        } else {
            //  For small options before TWAP available, use conservative pricing
            // Revert for large options to prevent manipulation
            uint256 notionalValueETH = (notionalAmount * strikePrice) / 1e18;

            if (notionalValueETH > 1 ether) {
                // Large option requires TWAP data
                revert NoBaseFeeData();
            }

            // For small options (<1 ETH notional), use current basefee with safety margin
            // Add 20% to protect protocol from manipulation
            spotPrice = (block.basefee * 120) / 100;
        }

        // Time to expiry as fraction of year
        uint256 timeToExpiry = (duration * PRECISION) / 365 days;
        uint256 sqrtTime = timeToExpiry.sqrt();

        // Volatility factor
        uint256 volFactor = (impliedVolatility * PRECISION) / 100;

        //  Removed unnecessary uint128 overflow checks
        // Calculate with overflow protection using mulDiv
        uint256 volProduct = spotPrice.mulDiv(volFactor, PRECISION);
        uint256 timeValue = volProduct.mulDiv(sqrtTime, PRECISION);

        // Intrinsic value
        uint256 intrinsicValue = 0;
        if (isCall && spotPrice > strikePrice) {
            intrinsicValue = spotPrice - strikePrice;
        } else if (!isCall && strikePrice > spotPrice) {
            intrinsicValue = strikePrice - spotPrice;
        }

        // Total premium per gas unit
        uint256 premiumPerUnit = intrinsicValue + timeValue;

        // Apply minimum premium
        uint256 minPremium = (spotPrice * minPremiumBps) / BPS_DENOMINATOR;
        if (premiumPerUnit < minPremium) {
            premiumPerUnit = minPremium;
        }

        // Check overflow before multiplication
        if (premiumPerUnit > type(uint256).max / notionalAmount) {
            revert PremiumTooHigh();
        }

        uint256 totalPremium = premiumPerUnit * notionalAmount;

        //  Cap instead of revert for max premium check
        // Dynamic cap based on notional value
        uint256 notionalValueETH = (notionalAmount * strikePrice) / 1e18;
        uint256 maxPremium = notionalValueETH * MAX_PREMIUM_MULTIPLIER;

        if (totalPremium > maxPremium) {
            totalPremium = maxPremium; //  CAP instead of REVERT
        }

        return totalPremium;
    }
    /**
     * @notice Get TWAP of base fee using circular buffer
     */
    function _getBaseFeeTWAP(uint256 window) internal view returns (uint256) {
        if (window > 24 hours) revert TWAPWindowTooLarge();
        if (snapshotCount == 0) revert NoBaseFeeData();

        uint256 cutoff = block.timestamp - window;
        uint256 sum = 0;
        uint256 count = 0;

        // Calculate starting index for circular buffer
        uint256 startIndex = snapshotCount < MAX_BASEFEE_SNAPSHOTS
            ? 0
            : baseFeeHead;

        // Iterate through circular buffer
        for (uint256 i = 0; i < snapshotCount; i++) {
            uint256 index = (startIndex + i) % MAX_BASEFEE_SNAPSHOTS;
            BaseFeeSnapshot memory snapshot = baseFeeSnapshots[index];

            // Only include snapshots within window
            if (snapshot.timestamp >= cutoff) {
                sum += snapshot.baseFee;
                count++;
            }
        }

        if (count == 0) {
            // Fallback to current base fee
            return block.basefee;
        }

        return sum / count;
    }

    /**
     * @notice Check and update daily options limit
     * @dev PRESERVED circuit breaker logic
     */
    function _checkDailyOptionsLimit(uint256 premium) internal {
        // Reset daily counter if needed
        if (block.timestamp > lastOptionsReset + 1 days) {
            dailyOptionsVolume = 0;
            lastOptionsReset = block.timestamp;
        }

        if (dailyOptionsVolume + premium > maxDailyOptionsVolume) {
            revert DailyLimitExceeded();
        }
    }

    // ═══════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Get treasury statistics
     */
    function getTreasuryStats()
        external
        view
        returns (
            uint256 shieldBalance,
            uint256 ethBalance,
            uint256 totalFees,
            uint256 mintFees,
            uint256 redeemFees,
            uint256 managementFees,
            uint256 optionsVolume,
            uint256 optionPayouts,
            uint256 pendingPayoutsTotal
        )
    {
        return (
            treasuryShieldBalance,
            treasuryETHBalance,
            totalFeesCollected,
            lifetimeMintFees,
            lifetimeRedeemFees,
            lifetimeManagementFees,
            totalOptionsVolume,
            totalPayouts,
            totalPendingPayouts
        );
    }

    /**
     * @notice Get user's pending payout
     */
    function getPendingPayout(address user) external view returns (uint256) {
        return pendingPayouts[user];
    }

    /**
     * @notice Get user's active options
     */
    function getUserOptions(
        address user
    ) external view returns (uint256[] memory) {
        return userOptions[user];
    }

    /**
     * @notice Get option details
     */
    function getOption(
        uint256 optionId
    ) external view returns (GasOption memory) {
        return gasOptions[optionId];
    }

    /**
     * @notice Get current base fee TWAP
     */
    function getCurrentGasPriceTWAP(
        uint256 window
    ) external view returns (uint256) {
        return _getBaseFeeTWAP(window);
    }

    /**
     * @notice Check if option is exercisable
     */
    function isOptionExercisable(
        uint256 optionId
    ) external view returns (bool isExercisable, uint256 estimatedPayoff) {
        GasOption memory option = gasOptions[optionId];

        if (!option.isActive || option.isExercised) {
            return (false, 0);
        }

        if (block.timestamp > option.expiryTimestamp) {
            return (false, 0);
        }

        uint256 currentGasPrice = snapshotCount >= 12
            ? _getBaseFeeTWAP(1 hours)
            : block.basefee;

        if (option.isCall) {
            if (currentGasPrice > option.strikePrice) {
                uint256 diff = currentGasPrice - option.strikePrice;
                estimatedPayoff = diff * option.notionalAmount;

                uint256 maxPayoff = option.premium * MAX_PAYOFF_MULTIPLIER;
                if (estimatedPayoff > maxPayoff) {
                    estimatedPayoff = maxPayoff;
                }

                isExercisable = true;
            }
        } else {
            if (option.strikePrice > currentGasPrice) {
                uint256 diff = option.strikePrice - currentGasPrice;
                estimatedPayoff = diff * option.notionalAmount;

                uint256 maxPayoff = option.premium * MAX_PAYOFF_MULTIPLIER;
                if (estimatedPayoff > maxPayoff) {
                    estimatedPayoff = maxPayoff;
                }

                isExercisable = true;
            }
        }

        return (isExercisable, estimatedPayoff);
    }

    /**
     * @notice Calculate premium for given parameters
     */
    function calculatePremium(
        uint256 strikePrice,
        uint256 notionalAmount,
        uint256 duration,
        bool isCall
    ) external view returns (uint256 premium) {
        // Validate inputs
        if (strikePrice == 0 || strikePrice > MAX_STRIKE_PRICE) {
            return 0;
        }
        if (notionalAmount == 0 || notionalAmount > MAX_NOTIONAL) {
            return 0;
        }
        if (duration < MIN_OPTION_DURATION || duration > MAX_OPTION_DURATION) {
            return 0;
        }

        return
            _calculateOptionPremium(
                strikePrice,
                notionalAmount,
                duration,
                isCall
            );
    }

    /**
     * @notice Get base fee snapshot at index
     */
    function getBaseFeeSnapshot(
        uint256 index
    ) external view returns (uint256 baseFee, uint256 timestamp) {
        require(index < snapshotCount, "Index out of bounds");

        uint256 actualIndex;
        if (snapshotCount < MAX_BASEFEE_SNAPSHOTS) {
            actualIndex = index;
        } else {
            actualIndex = (baseFeeHead + index) % MAX_BASEFEE_SNAPSHOTS;
        }

        BaseFeeSnapshot memory snapshot = baseFeeSnapshots[actualIndex];
        return (snapshot.baseFee, snapshot.timestamp);
    }

    /**
     * @notice Get all base fee snapshots in chronological order
     */
    function getAllBaseFeeSnapshots()
        external
        view
        returns (uint256[] memory baseFees, uint256[] memory timestamps)
    {
        baseFees = new uint256[](snapshotCount);
        timestamps = new uint256[](snapshotCount);

        for (uint256 i = 0; i < snapshotCount; i++) {
            uint256 actualIndex;
            if (snapshotCount < MAX_BASEFEE_SNAPSHOTS) {
                actualIndex = i;
            } else {
                actualIndex = (baseFeeHead + i) % MAX_BASEFEE_SNAPSHOTS;
            }

            BaseFeeSnapshot memory snapshot = baseFeeSnapshots[actualIndex];
            baseFees[i] = snapshot.baseFee;
            timestamps[i] = snapshot.timestamp;
        }

        return (baseFees, timestamps);
    }

    /**
     * @notice Get options market statistics
     */
    function getOptionsStats()
        external
        view
        returns (
            uint256 totalVolume,
            uint256 dailyVolume,
            uint256 dailyLimit,
            uint256 totalPayouts_,
            uint256 currentIV,
            uint256 activeOptionsCount
        )
    {
        // Check if daily counter needs reset
        uint256 currentDailyVolume = dailyOptionsVolume;
        if (block.timestamp > lastOptionsReset + 1 days) {
            currentDailyVolume = 0;
        }

        // Count active options
        uint256 activeCount = 0;
        for (uint256 i = 1; i <= optionIdCounter; i++) {
            if (gasOptions[i].isActive) {
                activeCount++;
            }
        }

        return (
            totalOptionsVolume,
            currentDailyVolume,
            maxDailyOptionsVolume,
            totalPayouts,
            impliedVolatility,
            activeCount
        );
    }

    /**
     * @notice Get user's active options count
     */
    function getUserActiveOptionsCount(
        address user
    ) external view returns (uint256 count) {
        uint256[] memory optionIds = userOptions[user];
        for (uint256 i = 0; i < optionIds.length; i++) {
            if (gasOptions[optionIds[i]].isActive) {
                count++;
            }
        }
        return count;
    }

    /**
     * @notice Get base fee history length
     */
    function getBaseFeeHistoryLength() external view returns (uint256) {
        return snapshotCount;
    }

    /**
     * @notice Get current implied volatility
     */
    function getCurrentIV() external view returns (uint256) {
        return impliedVolatility;
    }

    // ═══════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Configure TWAP safety parameters
     * @param _minSnapshots Minimum snapshots required for TWAP
     * @param _maxDeviationBps Maximum spot price deviation (BPS)
     */
    function setTWAPParameters(
        uint256 _minSnapshots,
        uint256 _maxDeviationBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_minSnapshots >= 6, "Too few snapshots"); // Min 30 minutes
        require(_minSnapshots <= MAX_BASEFEE_SNAPSHOTS, "Exceeds max");
        require(_maxDeviationBps <= 5000, "Deviation too high"); // Max 50%

        minTWAPSnapshots = _minSnapshots;
        maxSpotDeviationBps = _maxDeviationBps;
    }
    /**
     * @notice Update options market parameters
     * @param _impliedVolatility New IV (20-200%)
     * @param _minPremiumBps New minimum premium (BPS)
     */
    function setOptionsParameters(
        uint256 _impliedVolatility,
        uint256 _minPremiumBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            _impliedVolatility >= 20 && _impliedVolatility <= 200,
            "IV out of range"
        );
        require(_minPremiumBps <= 100, "Min premium too high");

        impliedVolatility = _impliedVolatility;
        minPremiumBps = _minPremiumBps;
    }

    /**
     * @notice Set daily options volume limit
     * @param _maxDailyOptions New daily limit (in wei)
     */
    function setDailyOptionsLimit(
        uint256 _maxDailyOptions
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxDailyOptions > 0, "Invalid limit");
        maxDailyOptionsVolume = _maxDailyOptions;
    }

    /**
     * @notice Withdraw SHIELD tokens from treasury
     * @param recipient Recipient address
     * @param amount Amount to withdraw
     * @dev For protocol development, marketing, partnerships
     */
    function withdrawShield(
        address recipient,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount > treasuryShieldBalance)
            revert InsufficientTreasuryBalance();

        treasuryShieldBalance -= amount;

        shieldToken.safeTransfer(recipient, amount);

        emit TreasuryWithdrawal(recipient, address(shieldToken), amount);
    }

    /**
     * @notice Withdraw ETH from treasury (for operations)
     * @param recipient Recipient address
     * @param amount Amount to withdraw
     * @dev Keep sufficient balance for options payouts
     */
    function withdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient();

        // Ensure we keep enough for pending payouts
        uint256 availableBalance = treasuryETHBalance - totalPendingPayouts;
        if (amount > availableBalance) revert InsufficientTreasuryBalance();

        treasuryETHBalance -= amount;

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit TreasuryWithdrawal(recipient, address(0), amount);
    }

    /**
     * @notice Emergency pause all operations
     * @param reason Reason for pause
     */
    function emergencyPause(
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) {
        _pause();
        emit EmergencyShutdown(msg.sender, reason);
    }

    /**
     * @notice Resume operations after pause
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Force expire an option (emergency only)
     * @param optionId Option ID to expire
     */
    function forceExpireOption(
        uint256 optionId
    ) external onlyRole(EMERGENCY_ROLE) {
        GasOption storage option = gasOptions[optionId];
        require(option.isActive, "Option not active");

        option.isActive = false;
        emit GasOptionExpired(optionId);
    }

    /**
     * @notice Force settle pending payout (emergency only)
     * @param user User with pending payout
     * @param recipient Alternative recipient address
     * @dev Use when user's address cannot receive ETH
     */
    function forceSettlePayout(
        address user,
        address payable recipient
    ) external onlyRole(EMERGENCY_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient();

        uint256 amount = pendingPayouts[user];
        require(amount > 0, "No payout");

        pendingPayouts[user] = 0;
        totalPendingPayouts -= amount;

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            // Revert effects on failure
            pendingPayouts[user] = amount;
            totalPendingPayouts += amount;
            revert TransferFailed();
        }

        emit PayoutWithdrawn(user, amount);
    }

    /**
     * @notice Emergency withdraw any ERC20 token
     * @param token Token address
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function emergencyWithdrawToken(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(EMERGENCY_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient();

        // Don't allow withdrawing SHIELD beyond available balance
        if (token == address(shieldToken)) {
            require(amount <= treasuryShieldBalance, "Exceeds SHIELD balance");
            treasuryShieldBalance -= amount;
        }

        IERC20(token).safeTransfer(recipient, amount);

        emit TreasuryWithdrawal(recipient, token, amount);
    }

    /**
     * @notice Emergency withdraw ETH (bypass checks)
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function emergencyWithdrawETH(
        uint256 amount,
        address payable recipient
    ) external onlyRole(EMERGENCY_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient();

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit TreasuryWithdrawal(recipient, address(0), amount);
    }
    /**
     * @notice Marker function to validate TreasuryController
     */
    function isTreasuryController() external pure returns (bool) {
        return true;
    }
    // ═══════════════════════════════════════════════════════════
    // RECEIVE ETHER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Receive ETH for gas option payouts
     */
    receive() external payable {
        treasuryETHBalance += msg.value;
    }

    /**
     * @notice Fallback function
     */
    fallback() external payable {
        treasuryETHBalance += msg.value;
    }
}
