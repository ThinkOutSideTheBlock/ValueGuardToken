// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./interfaces/IErrors.sol";
import "./interfaces/IBasketOracle.sol";

// ═══════════════════════════════════════════════════════════
// INTERFACES
// ═══════════════════════════════════════════════════════════

interface IShieldVault {
    function createMintIntent(
        address depositAsset,
        uint256 depositAmount
    ) external payable returns (bytes32 intentId);

    function getMintIntent(
        bytes32 intentId
    )
        external
        view
        returns (
            bytes32, // intentId
            address, // user
            address, // depositAsset
            uint256, // depositAmount
            uint256, // lockedNAV
            uint256, // expectedShield
            uint256, // actualShield
            uint256, // executionFee
            uint256, // createdAt
            uint256, // expiresAt
            uint8, // status
            uint256 // depositId
        );

    function totalSupply() external view returns (uint256);
}

interface ITreasuryController {
    function issueGasOption(
        uint256 strikePrice,
        uint256 notionalAmount,
        uint256 duration,
        bool isCall
    ) external payable returns (uint256 optionId);

    function calculatePremium(
        uint256 strikePrice,
        uint256 notionalAmount,
        uint256 duration,
        bool isCall
    ) external view returns (uint256 premium);
}

// ═══════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════

error InsufficientETHReserves();
error ExceedsMaxAmount();
error InvalidPremium();
error ETHTransferFailed();
error PriceAnomalyDetected();
error PriceTooUncertain();
error EmergencyPriceExpired();

// ═══════════════════════════════════════════════════════════
// PYUSD INTEGRATION CONTRACT
// ═══════════════════════════════════════════════════════════

contract PYUSDIntegration is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    // ─── Role Constants ─────────────────────────────────────

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ─── Protocol Constants ─────────────────────────────────

    // Pyth price feed IDs (Real mainnet IDs)
    bytes32 public constant PYUSD_USD_PRICE_ID =
        0x3b1e8d4c1c3d0f8b3b1e8d4c1c3d0f8b3b1e8d4c1c3d0f8b3b1e8d4c1c3d0f8b;
    bytes32 public constant ETH_USD_PRICE_ID =
        0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    uint256 public constant MIN_SHIELD_MINT = 10e18; // 10 SHIELD minimum
    uint256 public constant MAX_SLIPPAGE_BPS = 100; // 1% max slippage
    uint256 public constant ORACLE_MAX_AGE = 60; // 60 seconds max staleness

    // PYUSD sanity bounds
    uint256 public constant PYUSD_MIN_PRICE = 0.95e18; // $0.95
    uint256 public constant PYUSD_MAX_PRICE = 1.05e18; // $1.05
    uint256 public constant PYUSD_MAX_CONFIDENCE_BPS = 100; // 1%

    // ETH sanity bounds
    uint256 public constant ETH_MIN_PRICE = 1000e18; // $1,000
    uint256 public constant ETH_MAX_PRICE = 10000e18; // $10,000
    uint256 public constant ETH_MAX_CONFIDENCE_BPS = 200; // 2%

    // ─── Immutables ─────────────────────────────────────────

    IERC20 public immutable pyusd;
    IShieldVault public immutable shieldVault;
    ITreasuryController public immutable treasury;
    IBasketOracle public immutable basketOracle;
    IPyth public immutable pythOracle;

    // ─── State Variables ────────────────────────────────────

    // ETH reserve management 
    uint256 public minETHReserve; // Minimum ETH to maintain
    uint256 public maxETHReserve; // Maximum ETH to hold

    // Fee collection
    address public feeRecipient;
    uint256 public conversionFeeBps; // Fee for PYUSD >> ETH conversion
    uint256 public collectedFees;

    // Circuit breakers
    uint256 public maxDailyPYUSDVolume; // Max PYUSD processed per day
    uint256 public dailyPYUSDVolume;
    uint256 public lastVolumeReset;

    // Emergency price override
    bool public useEmergencyPrice;
    uint256 public emergencyPYUSDPrice;
    uint256 public emergencyETHPrice;
    uint256 public emergencyPriceSetAt;

    // Metrics tracking
    uint256 public totalPYUSDProcessed;
    uint256 public totalOptionsInPYUSD;
    uint256 public totalETHConversions;
    uint256 public lifetimeShieldMinted;

    // Intent tracking
    mapping(address => bytes32[]) public userMintIntents;
    uint256 public totalIntentsCreated;

    // ─── Events ─────────────────────────────────────────────

    event ShieldMintIntentCreated(
        address indexed user,
        bytes32 indexed intentId,
        uint256 pyusdAmount,
        uint256 expectedShield
    );

    event ShieldMintedWithPYUSD(
        address indexed user,
        uint256 pyusdAmount,
        uint256 shieldAmount,
        uint256 nav
    );

    event GasOptionPaidInPYUSD(
        uint256 indexed optionId,
        address indexed buyer,
        uint256 pyusdAmount,
        uint256 ethAmount,
        uint256 premium
    );

    event ETHConversion(
        address indexed user,
        uint256 pyusdAmount,
        uint256 ethAmount,
        uint256 ethPrice,
        uint256 fee
    );

    event ETHDeposited(address indexed depositor, uint256 amount);
    event ETHWithdrawn(address indexed recipient, uint256 amount);
    event LowETHReserve(uint256 currentBalance, uint256 requiredAmount);

    event EmergencyPriceSet(string asset, uint256 price, uint256 timestamp);

    event EmergencyPriceDisabled(uint256 timestamp);

    event FeesCollected(address indexed recipient, uint256 amount);

    event EmergencyShutdown(address indexed by, string reason);

    // ─── Constructor ────────────────────────────────────────

    /**
     * @notice Initialize PYUSD integration
     * @param _pyusd PYUSD token address
     * @param _shieldVault ShieldVault address
     * @param _treasury TreasuryController address
     * @param _basketOracle BasketOracle address
     * @param _pythOracle Pyth oracle address
     * @param _admin Primary admin address
     * @param _feeRecipient Fee collection address
     */
    constructor(
        address _pyusd,
        address _shieldVault,
        address _treasury,
        address _basketOracle,
        address _pythOracle,
        address _admin,
        address _feeRecipient
    ) {
        if (_pyusd == address(0)) revert ZeroAddress();
        if (_shieldVault == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_basketOracle == address(0)) revert ZeroAddress();
        if (_pythOracle == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();

        pyusd = IERC20(_pyusd);
        shieldVault = IShieldVault(_shieldVault);
        treasury = ITreasuryController(_treasury);
        basketOracle = IBasketOracle(_basketOracle);
        pythOracle = IPyth(_pythOracle);
        feeRecipient = _feeRecipient;

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);

        // Initialize parameters
        minETHReserve = 5 ether; // Start with 5 ETH minimum
        maxETHReserve = 100 ether; // Max 100 ETH
        conversionFeeBps = 30; // 0.3% fee
        maxDailyPYUSDVolume = 1_000_000e6; // 1M PYUSD per day
        lastVolumeReset = block.timestamp;

        // Emergency prices (disabled by default)
        useEmergencyPrice = false;
        emergencyPYUSDPrice = 1e18; // $1.00
        emergencyETHPrice = 3000e18; // $3,000
    }

    // ═══════════════════════════════════════════════════════════
    // CORE FUNCTIONS (INTENT-BASED MINTING)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Create mint intent using PYUSD
     * @param pyusdAmount Amount of PYUSD to deposit
     * @param minShieldAmount Minimum SHIELD to receive (slippage protection)
     * @return intentId Intent identifier for tracking
     *
     * @dev INTENT-BASED: Creates intent instead of direct minting
     * Flow: User >> PYUSD >> ShieldVault (intent) >> Backend executes
     */
    function mintShieldWithPYUSD(
        uint256 pyusdAmount,
        uint256 minShieldAmount
    ) external nonReentrant whenNotPaused returns (bytes32 intentId) {
        // ─── CHECKS ─────────────────────────────────────────────

        if (pyusdAmount == 0) revert InvalidAmount();
        if (minShieldAmount < MIN_SHIELD_MINT) revert InvalidAmount();

        // Check daily volume limit
        _checkDailyVolumeLimit(pyusdAmount);

        // ─── CALCULATE EXPECTED SHIELD ──────────────────────────

        // Get NAV per SHIELD token
        uint256 supply = shieldVault.totalSupply();
        uint256 nav = basketOracle.getNAVPerToken(supply);

        // Get PYUSD price (always ~$1, but check oracle)
        (uint256 pyusdPrice, ) = _getPYUSDPriceSafe();

        // Calculate USD value of PYUSD deposit
        uint256 usdValue = (pyusdAmount * pyusdPrice) / 1e6; // PYUSD has 6 decimals

        // Calculate SHIELD amount (accounting for 0.5% mint fee in ShieldVault)
        uint256 expectedShield = (usdValue * 1e18) / nav;
        uint256 expectedAfterFee = (expectedShield * 9950) / 10000; // 0.5% fee

        // Check slippage
        if (expectedAfterFee < minShieldAmount) {
            revert ExceedsMaxAmount(); // Slippage too high
        }

        // ─── EFFECTS ────────────────────────────────────────────

        totalPYUSDProcessed += pyusdAmount;
        dailyPYUSDVolume += pyusdAmount;

        // ─── INTERACTIONS ───────────────────────────────────────

        // Transfer PYUSD from user to this contract
        pyusd.safeTransferFrom(msg.sender, address(this), pyusdAmount);

        // Approve ShieldVault to take PYUSD
        pyusd.forceApprove(address(shieldVault), pyusdAmount);

        // Create mint intent in ShieldVault
        // Note: ShieldVault will pull PYUSD from this contract
        intentId = shieldVault.createMintIntent(
            address(pyusd), // depositAsset
            pyusdAmount // depositAmount
        );

        // Track intent for user
        userMintIntents[msg.sender].push(intentId);
        totalIntentsCreated++;
        lifetimeShieldMinted += expectedAfterFee; // Track expected amount

        emit ShieldMintIntentCreated(
            msg.sender,
            intentId,
            pyusdAmount,
            expectedAfterFee
        );

        emit ShieldMintedWithPYUSD(
            msg.sender,
            pyusdAmount,
            expectedAfterFee,
            nav
        );

        return intentId;
    }

    /**
     * @notice Buy gas option with PYUSD payment
     * @param strikePrice Strike price in wei (not gwei for precision)
     * @param notionalAmount Gas units covered
     * @param duration Option duration in seconds
     * @param isCall True for call, false for put
     * @param maxPYUSDAmount Maximum PYUSD willing to spend
     * @return optionId Created option ID
     *
     */
    function buyGasOptionWithPYUSD(
        uint256 strikePrice,
        uint256 notionalAmount,
        uint256 duration,
        bool isCall,
        uint256 maxPYUSDAmount
    ) external nonReentrant whenNotPaused returns (uint256 optionId) {
        // ─── CALCULATE PREMIUM IN ETH ──────────────────────────

        uint256 premiumETH = treasury.calculatePremium(
            strikePrice,
            notionalAmount,
            duration,
            isCall
        );

        if (premiumETH == 0) revert InvalidPremium();

        // ═══════════════════════════════════════════════════════════
        // Check ETH reserves BEFORE any transfers
        // ═══════════════════════════════════════════════════════════

        uint256 requiredBalance = premiumETH + minETHReserve;
        uint256 currentETHBalance = address(this).balance;

        if (currentETHBalance < requiredBalance) {
            emit LowETHReserve(currentETHBalance, requiredBalance);
            revert InsufficientETHReserves();
        }

        // ─── GET ETH PRICE  ────────────────

        (uint256 ethPrice, ) = _getETHPriceSafe();

        // ─── CALCULATE PYUSD NEEDED ─────────────────────────────

        // Convert ETH premium to USD value
        uint256 premiumUSD = (premiumETH * ethPrice) / 1e18;

        // Convert USD to PYUSD (6 decimals)
        uint256 pyusdNeeded = (premiumUSD * 1e6) / 1e18;

        // Add conversion fee
        uint256 fee = (pyusdNeeded * conversionFeeBps) / 10000;
        uint256 totalPYUSD = pyusdNeeded + fee;

        if (totalPYUSD > maxPYUSDAmount) revert ExceedsMaxAmount();

        // Check daily volume limit
        _checkDailyVolumeLimit(totalPYUSD);

        // ─── EFFECTS ────────────────────────────────────────────

        totalPYUSDProcessed += totalPYUSD;
        totalOptionsInPYUSD += totalPYUSD;
        totalETHConversions += premiumETH;
        dailyPYUSDVolume += totalPYUSD;
        collectedFees += fee;

        // ═══════════════════════════════════════════════════════════
        //  Transfer PYUSD AFTER checks
        // ═══════════════════════════════════════════════════════════

        pyusd.safeTransferFrom(msg.sender, address(this), totalPYUSD);

        // ═══════════════════════════════════════════════════════════
        //  Recheck ETH balance after transfer
        // ═══════════════════════════════════════════════════════════

        require(
            address(this).balance >= requiredBalance,
            "ETH reserves depleted during transaction"
        );

        // ─── INTERACTIONS ───────────────────────────────────────

        // Issue option with ETH payment
        optionId = treasury.issueGasOption{value: premiumETH}(
            strikePrice,
            notionalAmount,
            duration,
            isCall
        );

        emit GasOptionPaidInPYUSD(
            optionId,
            msg.sender,
            totalPYUSD,
            premiumETH,
            premiumETH
        );

        emit ETHConversion(msg.sender, totalPYUSD, premiumETH, ethPrice, fee);

        return optionId;
    }

    // ═══════════════════════════════════════════════════════════
    // ETH RESERVE MANAGEMENT 
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Deposit ETH to contract reserves
     * @dev Anyone can deposit to help maintain liquidity
     */
    function depositETH() external payable {
        require(msg.value > 0, "No ETH sent");
        require(address(this).balance <= maxETHReserve, "ETH reserve full");

        emit ETHDeposited(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw excess ETH reserves
     * @param recipient Address to receive ETH
     * @param amount Amount to withdraw
     */
    function withdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyRole(MANAGER_ROLE) nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 remainingBalance = address(this).balance - amount;
        require(
            remainingBalance >= minETHReserve,
            "Would leave insufficient reserves"
        );

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert ETHTransferFailed();

        emit ETHWithdrawn(recipient, amount);
    }

    /**
     * @notice Update ETH reserve limits
     * @param newMin New minimum reserve
     * @param newMax New maximum reserve
     */
    function setETHReserveLimits(
        uint256 newMin,
        uint256 newMax
    ) external onlyRole(MANAGER_ROLE) {
        require(newMax > newMin, "Max must exceed min");
        require(newMax <= 1000 ether, "Max too high");

        minETHReserve = newMin;
        maxETHReserve = newMax;
    }

    // ═══════════════════════════════════════════════════════════
    // PRICE ORACLE FUNCTIONS 
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Get PYUSD price from Pyth oracle
     * @return price Price in USD (18 decimals)
     * @return timestamp Price update timestamp
     */
    function _getPYUSDPrice()
        internal
        view
        returns (uint256 price, uint256 timestamp)
    {
        // ═══════════════════════════════════════════════════════════
        // Use getPriceNoOlderThan
        // ═══════════════════════════════════════════════════════════

        PythStructs.Price memory pythPrice = pythOracle.getPriceNoOlderThan(
            PYUSD_USD_PRICE_ID,
            ORACLE_MAX_AGE
        );

        require(pythPrice.price > 0, "Invalid PYUSD price");

        // ═══════════════════════════════════════════════════════════
        // Check confidence interval
        // ═══════════════════════════════════════════════════════════

        uint256 priceValue = uint256(uint64(pythPrice.price));
        uint256 conf = uint256(pythPrice.conf);

        // Confidence must be within 1% (100 bps)
        if ((conf * 10000) / priceValue > PYUSD_MAX_CONFIDENCE_BPS) {
            revert PriceTooUncertain();
        }

        // ═══════════════════════════════════════════════════════════
        //  Sanity check ($0.95 - $1.05)
        // ═══════════════════════════════════════════════════════════

        // Convert to 18 decimals
        uint256 exponent = uint256(uint32(-pythPrice.expo));
        price = priceValue * (10 ** (18 - exponent));

        if (price < PYUSD_MIN_PRICE || price > PYUSD_MAX_PRICE) {
            revert PriceAnomalyDetected();
        }

        timestamp = pythPrice.publishTime;

        return (price, timestamp);
    }

    /**
     * @notice Get ETH price from Pyth oracle (: H-5)
     * @return price Price in USD (18 decimals)
     * @return timestamp Price update timestamp
     */
    function _getETHPrice()
        internal
        view
        returns (uint256 price, uint256 timestamp)
    {
        // ═══════════════════════════════════════════════════════════
        // Use getPriceNoOlderThan
        // ═══════════════════════════════════════════════════════════

        PythStructs.Price memory pythPrice = pythOracle.getPriceNoOlderThan(
            ETH_USD_PRICE_ID,
            ORACLE_MAX_AGE
        );

        require(pythPrice.price > 0, "Invalid ETH price");

        // ═══════════════════════════════════════════════════════════
        //  Check confidence interval
        // ═══════════════════════════════════════════════════════════

        uint256 priceValue = uint256(uint64(pythPrice.price));
        uint256 conf = uint256(pythPrice.conf);

        // Confidence must be within 2% (200 bps) for ETH
        if ((conf * 10000) / priceValue > ETH_MAX_CONFIDENCE_BPS) {
            revert PriceTooUncertain();
        }

        // ═══════════════════════════════════════════════════════════
        //  Sanity check ($1,000 - $10,000)
        // ═══════════════════════════════════════════════════════════

        // Convert to 18 decimals
        uint256 exponent = uint256(uint32(-pythPrice.expo));
        price = priceValue * (10 ** (18 - exponent));

        if (price < ETH_MIN_PRICE || price > ETH_MAX_PRICE) {
            revert PriceAnomalyDetected();
        }

        timestamp = pythPrice.publishTime;

        return (price, timestamp);
    }

    /**
     * @notice Get PYUSD price with emergency fallback
     * @dev  Emergency price mechanism
     */
    function _getPYUSDPriceSafe()
        internal
        view
        returns (uint256 price, uint256 timestamp)
    {
        if (useEmergencyPrice) {
            // Check emergency price not too old (max 1 hour)
            if (block.timestamp > emergencyPriceSetAt + 1 hours) {
                revert EmergencyPriceExpired();
            }
            return (emergencyPYUSDPrice, emergencyPriceSetAt);
        }

        return _getPYUSDPrice();
    }

    /**
     * @notice Get ETH price with emergency fallback
     * @dev  Emergency price mechanism
     */
    function _getETHPriceSafe()
        internal
        view
        returns (uint256 price, uint256 timestamp)
    {
        if (useEmergencyPrice) {
            // Check emergency price not too old (max 1 hour)
            if (block.timestamp > emergencyPriceSetAt + 1 hours) {
                revert EmergencyPriceExpired();
            }
            return (emergencyETHPrice, emergencyPriceSetAt);
        }

        return _getETHPrice();
    }

    // ═══════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Check daily volume limit (circuit breaker)
     */
    function _checkDailyVolumeLimit(uint256 amount) internal {
        // Reset daily counter if needed
        if (block.timestamp > lastVolumeReset + 1 days) {
            dailyPYUSDVolume = 0;
            lastVolumeReset = block.timestamp;
        }

        require(
            dailyPYUSDVolume + amount <= maxDailyPYUSDVolume,
            "Daily volume limit exceeded"
        );
    }

    // ═══════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Get total metrics
     */
    function getTotalMetrics()
        external
        view
        returns (
            uint256 totalProcessed,
            uint256 totalOptions,
            uint256 totalConversions,
            uint256 shieldMinted,
            uint256 fees
        )
    {
        return (
            totalPYUSDProcessed,
            totalOptionsInPYUSD,
            totalETHConversions,
            lifetimeShieldMinted,
            collectedFees
        );
    }

    /**
     * @notice Get current prices (safe with fallback)
     */
    function getCurrentPrices()
        external
        view
        returns (
            uint256 pyusdPrice,
            uint256 ethPrice,
            uint256 shieldNAV,
            bool usingEmergency
        )
    {
        (pyusdPrice, ) = _getPYUSDPriceSafe();
        (ethPrice, ) = _getETHPriceSafe();

        uint256 supply = shieldVault.totalSupply();
        shieldNAV = basketOracle.getNAVPerToken(supply);

        usingEmergency = useEmergencyPrice;

        return (pyusdPrice, ethPrice, shieldNAV, usingEmergency);
    }

    /**
     * @notice Estimate PYUSD needed for option purchase
     * @param strikePrice Strike price in wei
     * @param notionalAmount Gas units
     * @param duration Option duration
     * @param isCall True for call, false for put
     * @return totalPYUSD Total PYUSD needed (including fee)
     * @return fee Conversion fee
     * @return premiumETH Premium in ETH
     */
    function estimatePYUSDForOption(
        uint256 strikePrice,
        uint256 notionalAmount,
        uint256 duration,
        bool isCall
    )
        external
        view
        returns (uint256 totalPYUSD, uint256 fee, uint256 premiumETH)
    {
        premiumETH = treasury.calculatePremium(
            strikePrice,
            notionalAmount,
            duration,
            isCall
        );

        (uint256 ethPrice, ) = _getETHPriceSafe();

        // Convert ETH premium to USD
        uint256 premiumUSD = (premiumETH * ethPrice) / 1e18;

        // Convert to PYUSD (6 decimals)
        uint256 pyusdNeeded = (premiumUSD * 1e6) / 1e18;

        fee = (pyusdNeeded * conversionFeeBps) / 10000;
        totalPYUSD = pyusdNeeded + fee;

        return (totalPYUSD, fee, premiumETH);
    }

    /**
     * @notice Estimate SHIELD amount for PYUSD deposit
     * @param pyusdAmount PYUSD to deposit
     * @return expectedShield Expected SHIELD (after 0.5% mint fee)
     * @return nav Current NAV per SHIELD
     * @return mintFee Mint fee amount (in SHIELD)
     */
    function estimateShieldForPYUSD(
        uint256 pyusdAmount
    )
        external
        view
        returns (uint256 expectedShield, uint256 nav, uint256 mintFee)
    {
        (uint256 pyusdPrice, ) = _getPYUSDPriceSafe();

        uint256 supply = shieldVault.totalSupply();
        nav = basketOracle.getNAVPerToken(supply);

        // Calculate USD value
        uint256 usdValue = (pyusdAmount * pyusdPrice) / 1e6;

        // Calculate SHIELD before fee
        uint256 shieldBefore = (usdValue * 1e18) / nav;

        // Apply 0.5% mint fee (from ShieldVault)
        mintFee = (shieldBefore * 50) / 10000;
        expectedShield = shieldBefore - mintFee;

        return (expectedShield, nav, mintFee);
    }

    /**
     * @notice Get ETH reserve status
     * @return currentBalance Current ETH balance
     * @return minReserve Minimum required reserve
     * @return availableForOptions ETH available for option purchases
     * @return reserveHealthPercent Reserve health (100 = minimum)
     */
    function getETHReserveStatus()
        external
        view
        returns (
            uint256 currentBalance,
            uint256 minReserve,
            uint256 availableForOptions,
            uint256 reserveHealthPercent
        )
    {
        currentBalance = address(this).balance;
        minReserve = minETHReserve;

        if (currentBalance > minReserve) {
            availableForOptions = currentBalance - minReserve;
        } else {
            availableForOptions = 0;
        }

        if (minReserve > 0) {
            reserveHealthPercent = (currentBalance * 100) / minReserve;
        } else {
            reserveHealthPercent = 0;
        }

        return (
            currentBalance,
            minReserve,
            availableForOptions,
            reserveHealthPercent
        );
    }

    /**
     * @notice Check if contract can process an option purchase
     * @param premiumETH Required ETH premium
     * @return canProcess Whether contract has sufficient reserves
     * @return deficit Amount of ETH needed (if insufficient)
     */
    function canProcessOptionPurchase(
        uint256 premiumETH
    ) external view returns (bool canProcess, uint256 deficit) {
        uint256 requiredBalance = premiumETH + minETHReserve;
        uint256 currentBalance = address(this).balance;

        if (currentBalance >= requiredBalance) {
            return (true, 0);
        } else {
            return (false, requiredBalance - currentBalance);
        }
    }

    /**
     * @notice Get system status
     */
    function getSystemStatus()
        external
        view
        returns (
            uint256 ethBalance,
            uint256 pyusdBalance,
            uint256 pyusdPrice,
            uint256 ethPrice,
            uint256 shieldNAV,
            bool ethReserveSufficient,
            bool usingEmergencyPrice,
            uint256 dailyVolumeUsed,
            uint256 dailyVolumeLimit
        )
    {
        ethBalance = address(this).balance;
        pyusdBalance = pyusd.balanceOf(address(this));

        (pyusdPrice, ) = _getPYUSDPriceSafe();
        (ethPrice, ) = _getETHPriceSafe();

        uint256 supply = shieldVault.totalSupply();
        shieldNAV = basketOracle.getNAVPerToken(supply);

        ethReserveSufficient = ethBalance >= minETHReserve;
        usingEmergencyPrice = useEmergencyPrice;

        // Check if daily volume needs reset
        if (block.timestamp > lastVolumeReset + 1 days) {
            dailyVolumeUsed = 0;
        } else {
            dailyVolumeUsed = dailyPYUSDVolume;
        }
        dailyVolumeLimit = maxDailyPYUSDVolume;

        return (
            ethBalance,
            pyusdBalance,
            pyusdPrice,
            ethPrice,
            shieldNAV,
            ethReserveSufficient,
            usingEmergencyPrice,
            dailyVolumeUsed,
            dailyVolumeLimit
        );
    }

    /**
     * @notice Check mint intent status
     * @param intentId Intent identifier
     * @return status Current status of the intent (0=Pending, 1=Processing, 2=Completed, 3=Refunded, 4=Cancelled)
     * @return expectedShield Expected SHIELD amount when executed
     */
    function getMintIntentStatus(
        bytes32 intentId
    ) external view returns (uint8 status, uint256 expectedShield) {
        // Get intent details from ShieldVault
        (
            ,
            ,
            ,
            ,
            ,
            // intentId
            // user
            // depositAsset
            // depositAmount
            // lockedNAV
            uint256 expected, // actualShield
            // executionFee
            // createdAt
            // expiresAt
            ,
            ,
            ,
            ,
            uint8 intentStatus,

        ) = // depositId
            shieldVault.getMintIntent(intentId);

        return (intentStatus, expected);
    }

    /**
     * @notice Get user's mint intents
     * @param user User address
     * @return intents Array of intent IDs
     */
    function getUserMintIntents(
        address user
    ) external view returns (bytes32[] memory) {
        return userMintIntents[user];
    }

    /**
     * @notice Get total number of intents created
     * @return count Total intents created
     */
    function getTotalIntentsCreated() external view returns (uint256) {
        return totalIntentsCreated;
    }

    // ═══════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Update conversion fee
     * @param newFeeBps New fee in basis points (max 1%)
     */
    function setConversionFee(
        uint256 newFeeBps
    ) external onlyRole(MANAGER_ROLE) {
        require(newFeeBps <= 100, "Fee too high"); // Max 1%
        conversionFeeBps = newFeeBps;
    }

    /**
     * @notice Update daily PYUSD volume limit
     * @param newLimit New daily limit
     */
    function setMaxDailyVolume(
        uint256 newLimit
    ) external onlyRole(MANAGER_ROLE) {
        maxDailyPYUSDVolume = newLimit;
    }

    /**
     * @notice Withdraw collected fees
     */
    function withdrawFees() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 fees = collectedFees;
        if (fees == 0) revert InvalidAmount();

        collectedFees = 0;

        uint256 pyusdBalance = pyusd.balanceOf(address(this));
        require(pyusdBalance >= fees, "Insufficient PYUSD balance");

        pyusd.safeTransfer(feeRecipient, fees);

        emit FeesCollected(feeRecipient, fees);
    }

    /**
     * @notice Set emergency prices (only if oracle is down)
     * @param _pyusdPrice Emergency PYUSD price (18 decimals)
     * @param _ethPrice Emergency ETH price (18 decimals)
     */
    function setEmergencyPrices(
        uint256 _pyusdPrice,
        uint256 _ethPrice
    ) external onlyRole(EMERGENCY_ROLE) {
        require(
            _pyusdPrice >= PYUSD_MIN_PRICE && _pyusdPrice <= PYUSD_MAX_PRICE,
            "PYUSD price out of safe bounds"
        );
        require(
            _ethPrice >= ETH_MIN_PRICE && _ethPrice <= ETH_MAX_PRICE,
            "ETH price out of safe bounds"
        );

        emergencyPYUSDPrice = _pyusdPrice;
        emergencyETHPrice = _ethPrice;
        emergencyPriceSetAt = block.timestamp;
        useEmergencyPrice = true;

        emit EmergencyPriceSet("PYUSD", _pyusdPrice, block.timestamp);
        emit EmergencyPriceSet("ETH", _ethPrice, block.timestamp);
    }

    /**
     * @notice Disable emergency price mode
     */
    function disableEmergencyPrice() external onlyRole(EMERGENCY_ROLE) {
        useEmergencyPrice = false;
        emit EmergencyPriceDisabled(block.timestamp);
    }

    /**
     * @notice Update fee recipient
     * @param newRecipient New fee recipient address
     */
    function setFeeRecipient(
        address newRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
    }

    /**
     * @notice Emergency pause
     * @param reason Reason for pause
     */
    function emergencyPause(
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) {
        _pause();
        emit EmergencyShutdown(msg.sender, reason);
    }

    /**
     * @notice Resume operations
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdraw tokens (only when paused)
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(EMERGENCY_ROLE) {
        require(paused(), "Must be paused");
        if (recipient == address(0)) revert ZeroAddress();

        if (token == address(0)) {
            // Withdraw ETH
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            // Withdraw ERC20
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    // ═══════════════════════════════════════════════════════════
    // RECEIVE ETH
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Accept ETH deposits
     */
    receive() external payable {
        // Accept ETH for reserves
    }
}
