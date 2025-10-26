// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./interfaces/IErrors.sol";
import "./interfaces/IBasketOracle.sol";

interface IBasketManager {
    function depositReserves(
        address token,
        uint256 amount,
        address from
    ) external payable;

    function withdrawReserves(
        address token,
        uint256 amount,
        address to
    ) external payable;

    function getTotalManagedValue() external view returns (uint256);

    function needsDeployment() external view returns (bool, uint256);
}
interface ITreasuryController {
    function notifyFeeCollection(
        uint256 amount,
        string memory feeType
    ) external;
    function isTreasuryController() external pure returns (bool);
}
// ═══════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════

error BelowMinimumMint();
error BelowMinimumRedeem();
error InsufficientReserves();
error InvalidDepositAsset();
error StablecoinNotSupported();
error ExceedsRedemptionLimit();
error RedemptionDelayActive();
error InvalidNAV();
error ProtocolPaused();
error BasketManagerNotSet();
error InsufficientExecutionFee();
error TreasuryNotSet();
error InvalidTreasuryInterface();
error ExecutionFeeTooHigh();

// ═══════════════════════════════════════════════════════════
// SHIELD VAULT CONTRACT
// ═══════════════════════════════════════════════════════════

contract ShieldVault is ERC20, ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── Role Constants ─────────────────────────────────────

    bytes32 public constant ORACLE_UPDATER_ROLE =
        keccak256("ORACLE_UPDATER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant BASKET_MANAGER_ROLE =
        keccak256("BASKET_MANAGER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE"); // Backend executor
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE"); // Backend executor
    // ─── Protocol Constants ─────────────────────────────────

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant PRECISION = 1e18;

    // Fee limits
    uint256 public constant MIN_MINT_AMOUNT = 10e18; // 10 USDC minimum
    uint256 public constant MIN_REDEEM_AMOUNT = 1e18; // 1 SHIELD minimum
    uint256 public constant MAX_MINT_FEE_BPS = 500; // 5% max
    uint256 public constant MAX_REDEEM_FEE_BPS = 500; // 5% max
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 200; // 2% annual max

    // Redemption limits
    uint256 public constant REDEMPTION_DELAY = 5 minutes; // Anti-manipulation
    uint256 public constant DAILY_REDEMPTION_LIMIT_BPS = 1000; // 10% of supply per day

    // Oracle parameters
    uint256 public constant PRICE_MAX_AGE = 30; // 60 seconds
    uint256 public constant TWAP_WINDOW = 15 minutes;

    //  Security constants
    uint256 public constant MAX_EXECUTION_FEE = 0.01 ether; // 10x normal GMX fee
    uint256 public constant FRACTIONAL_FEE_THRESHOLD = 1e15; // 0.001 SHIELD

    // ─── Immutables ─────────────────────────────────────────

    IBasketOracle public immutable oracle;
    IPyth public immutable pyth;

    // ─── State Variables ────────────────────────────────────

    ITreasuryController public treasury;
    address public basketManager; // Holds stablecoin reserves

    struct StablecoinConfig {
        address token;
        bytes32 pythPriceId; // For USDT/DAI (USDC assumed $1)
        uint8 decimals;
        bool isActive;
    }

    struct UserRedemption {
        uint256 lastRedemptionTime;
        uint256 amountRedeemedToday;
    }

    //  Global redemption tracking
    struct GlobalRedemptionTracking {
        uint256 totalVolumeToday;
        uint256 lastResetTime;
        uint256 uniqueRedeemersToday;
        mapping(address => bool) hasRedeemedToday;
    }

    // Supported stablecoins
    mapping(address => StablecoinConfig) public stablecoins;
    address[] public supportedStablecoins;

    // Fee structure
    uint256 public mintFeeBps; // e.g., 50 = 0.5%
    uint256 public redeemFeeBps; // e.g., 50 = 0.5%
    uint256 public managementFeeBps; // Annual fee (e.g., 100 = 1%)
    uint256 public lastManagementFeeCollection;

    //  Fractional fee accumulation
    uint256 public accumulatedFractionalFees; // Stores fractional fees in wei

    // Redemption tracking (per user)
    mapping(address => UserRedemption) public userRedemptions;
    uint256 public dailyRedemptionResetTime;
    uint256 public totalRedeemedToday;

    //  Global redemption tracking
    GlobalRedemptionTracking public globalRedemptions;

    // Protocol statistics
    uint256 public totalMinted;
    uint256 public totalRedeemed;
    uint256 public totalFeesCollected;
    uint256 public deploymentTime;

    // Intent structures
    enum IntentStatus {
        Pending, // Created, waiting for execution
        Processing, // Being processed (GMX deployment/closure)
        Completed, // Successfully executed
        Refunded, // Refunded due to failure/expiry
        Cancelled // Manually cancelled by user
    }

    struct MintIntent {
        bytes32 intentId;
        address user;
        address depositAsset;
        uint256 depositAmount;
        uint256 lockedNAV; // NAV at time of intent creation
        uint256 expectedShield; // Expected SHIELD to mint
        uint256 actualShield; // Actual SHIELD minted (may differ slightly)
        uint256 executionFee; // GMX execution fee paid
        uint256 createdAt;
        uint256 expiresAt; // Intent expires after 1 hour
        IntentStatus status;
        uint256 depositId; // BasketManager deposit ID
    }

    struct RedeemIntent {
        bytes32 intentId;
        address user;
        address outputAsset;
        uint256 shieldAmount;
        uint256 lockedNAV; // NAV at time of intent creation
        uint256 expectedStablecoin; // Expected stablecoin to receive
        uint256 actualStablecoin; // Actual stablecoin received
        uint256 executionFee; // GMX execution fee paid
        uint256 createdAt;
        uint256 expiresAt;
        IntentStatus status;
    }

    // Intent storage
    mapping(bytes32 => MintIntent) public mintIntents;
    mapping(bytes32 => RedeemIntent) public redeemIntents;
    mapping(address => bytes32[]) public userMintIntents;
    mapping(address => bytes32[]) public userRedeemIntents;

    uint256 public constant INTENT_EXPIRY = 1 hours; // Intents expire after 1 hour
    uint256 public totalIntentsCreated;
    uint256 public totalIntentsCompleted;
    uint256 public totalIntentsRefunded;
    // ─── Events ─────────────────────────────────────────────

    event ShieldMinted(
        address indexed user,
        address indexed depositAsset,
        uint256 depositAmount,
        uint256 shieldMinted,
        uint256 feeCollected,
        uint256 navPerToken
    );

    event ShieldRedeemed(
        address indexed user,
        address indexed outputAsset,
        uint256 shieldBurned,
        uint256 stablecoinReceived,
        uint256 feeCollected,
        uint256 navPerToken
    );

    event ManagementFeeCollected(uint256 feeAmount, uint256 timestamp);

    event StablecoinAdded(
        address indexed token,
        bytes32 pythPriceId,
        uint8 decimals
    );

    event StablecoinRemoved(address indexed token);

    event FeesUpdated(
        uint256 newMintFeeBps,
        uint256 newRedeemFeeBps,
        uint256 newManagementFeeBps
    );

    event BasketManagerUpdated(
        address indexed oldManager,
        address indexed newManager
    );

    event EmergencyShutdown(address indexed by, string reason);

    event GMXDeploymentTriggered(
        address indexed user,
        address indexed depositAsset,
        uint256 amount,
        uint256 executionFee
    );

    event GMXRedemptionTriggered(
        address indexed user,
        address indexed outputAsset,
        uint256 amount,
        uint256 executionFee
    );

    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );
    event GlobalRedemptionReset(uint256 timestamp, uint256 previousVolume);
    event SuspiciousRedemptionActivity(
        address indexed user,
        uint256 uniqueRedeemersToday,
        uint256 totalVolumeToday
    );
    event FractionalFeeAccumulated(uint256 totalAccumulated, uint256 threshold);

    event MintIntentCreated(
        bytes32 indexed intentId,
        address indexed user,
        address depositAsset,
        uint256 depositAmount,
        uint256 lockedNAV,
        uint256 expectedShield,
        uint256 executionFee,
        uint256 expiresAt
    );

    event MintIntentExecuted(
        bytes32 indexed intentId,
        address indexed user,
        uint256 actualShield,
        uint256 finalNAV,
        uint256 depositId
    );

    event MintIntentRefunded(
        bytes32 indexed intentId,
        address indexed user,
        uint256 refundAmount,
        string reason
    );

    event RedeemIntentCreated(
        bytes32 indexed intentId,
        address indexed user,
        address outputAsset,
        uint256 shieldAmount,
        uint256 lockedNAV,
        uint256 expectedStablecoin,
        uint256 executionFee,
        uint256 expiresAt
    );

    event RedeemIntentExecuted(
        bytes32 indexed intentId,
        address indexed user,
        uint256 actualStablecoin,
        uint256 finalNAV
    );

    event RedeemIntentRefunded(
        bytes32 indexed intentId,
        address indexed user,
        uint256 shieldRefund,
        string reason
    );

    event IntentCancelled(
        bytes32 indexed intentId,
        address indexed user,
        string intentType // "mint" or "redeem"
    );
    // ─── Constructor ────────────────────────────────────────

    /**
     * @notice Initialize SHIELD token
     * @param _oracle BasketOracle contract address
     * @param _pyth Pyth Network contract address
     * @param _admin Primary admin address
     */
    constructor(
        address _oracle,
        address _pyth,
        address _admin
    ) ERC20("SHIELD - Inflation Hedge Index", "SHIELD") {
        if (_oracle == address(0)) revert ZeroAddress();
        if (_pyth == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        oracle = IBasketOracle(_oracle);
        pyth = IPyth(_pyth);

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ORACLE_UPDATER_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        // Grant intent execution roles to admin initially
        // These will be transferred to backend hot wallet after deployment
        _grantRole(MINTER_ROLE, _admin);
        _grantRole(REDEEMER_ROLE, _admin);
        // Initialize fees (0.5% mint, 0.5% redeem, 1% annual management)
        mintFeeBps = 50;
        redeemFeeBps = 50;
        managementFeeBps = 100;
        lastManagementFeeCollection = block.timestamp;

        // Initialize redemption tracking
        dailyRedemptionResetTime = block.timestamp;
        deploymentTime = block.timestamp;

        //  Initialize global redemption tracking
        globalRedemptions.lastResetTime = block.timestamp;

        // Add USDC as default stablecoin (assumed $1, no oracle needed)
        _addStablecoin(
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC mainnet
            bytes32(0), // No oracle needed for USDC
            6
        );
    }

    // ═══════════════════════════════════════════════════════════
    // INTENT-BASED MINT FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Create mint intent (Step 1: User creates intent)
     * @dev User transfers stablecoins and creates pending intent
     * @param depositAsset Stablecoin address (USDC/USDT/DAI)
     * @param depositAmount Amount of stablecoin to deposit
     * @return intentId Unique identifier for this intent
     */
    function createMintIntent(
        address depositAsset,
        uint256 depositAmount
    ) external payable nonReentrant whenNotPaused returns (bytes32 intentId) {
        // ═══════════════════════════════════════════════════════════
        // CHECKS
        // ═══════════════════════════════════════════════════════════

        if (basketManager == address(0)) revert BasketManagerNotSet();
        if (msg.value > MAX_EXECUTION_FEE) revert ExecutionFeeTooHigh();

        StablecoinConfig memory stablecoin = stablecoins[depositAsset];
        if (!stablecoin.isActive) revert StablecoinNotSupported();
        if (depositAmount < MIN_MINT_AMOUNT) revert BelowMinimumMint();

        // Get current NAV and lock it
        uint256 navPerToken = _getCurrentNAV();
        if (navPerToken == 0) revert InvalidNAV();

        // Calculate expected SHIELD output
        uint256 depositAmountNormalized = _normalizeAmount(
            depositAmount,
            stablecoin.decimals
        );

        uint256 depositValueUSD = _getStablecoinValue(
            depositAsset,
            depositAmountNormalized
        );

        uint256 feeAmountUSD = (depositValueUSD * mintFeeBps) / BPS_DENOMINATOR;
        uint256 netDepositValue = depositValueUSD - feeAmountUSD;
        uint256 expectedShield = (netDepositValue * PRECISION) / navPerToken;

        if (expectedShield == 0) revert BelowMinimumMint();

        // ═══════════════════════════════════════════════════════════
        // EFFECTS
        // ═══════════════════════════════════════════════════════════

        // Generate unique intent ID
        intentId = keccak256(
            abi.encodePacked(
                msg.sender,
                depositAsset,
                depositAmount,
                block.timestamp,
                block.number,
                totalIntentsCreated
            )
        );

        // Store intent
        mintIntents[intentId] = MintIntent({
            intentId: intentId,
            user: msg.sender,
            depositAsset: depositAsset,
            depositAmount: depositAmount,
            lockedNAV: navPerToken,
            expectedShield: expectedShield,
            actualShield: 0,
            executionFee: msg.value,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + INTENT_EXPIRY,
            status: IntentStatus.Pending,
            depositId: 0
        });

        userMintIntents[msg.sender].push(intentId);
        totalIntentsCreated++;

        // ═══════════════════════════════════════════════════════════
        // INTERACTIONS
        // ═══════════════════════════════════════════════════════════

        // Transfer stablecoin from user to vault
        IERC20(depositAsset).safeTransferFrom(
            msg.sender,
            address(this),
            depositAmount
        );

        emit MintIntentCreated(
            intentId,
            msg.sender,
            depositAsset,
            depositAmount,
            navPerToken,
            expectedShield,
            msg.value,
            block.timestamp + INTENT_EXPIRY
        );

        return intentId;
    }

    /**
     * @notice Execute mint intent (Step 2: Backend executes after GMX deployment)
     * @dev Only callable by MINTER_ROLE (backend service)
     * @param intentId Intent identifier
     * @param depositId BasketManager deposit ID (from depositReserves)
     */
    function executeMintIntent(
        bytes32 intentId,
        uint256 depositId
    )
        external
        onlyRole(MINTER_ROLE)
        nonReentrant
        returns (uint256 shieldMinted)
    {
        MintIntent storage intent = mintIntents[intentId];

        // Validation
        require(intent.user != address(0), "Intent not found");
        require(intent.status == IntentStatus.Pending, "Intent not pending");
        require(block.timestamp <= intent.expiresAt, "Intent expired");

        // Mark as processing
        intent.status = IntentStatus.Processing;
        intent.depositId = depositId;

        // Get current NAV (may differ slightly from locked NAV)
        uint256 currentNAV = _getCurrentNAV();

        // Calculate final SHIELD amount
        // Use locked NAV if current NAV is within 0.5% (prevents slippage)
        uint256 navToUse = intent.lockedNAV;
        uint256 navDeviation = currentNAV > intent.lockedNAV
            ? ((currentNAV - intent.lockedNAV) * 10000) / intent.lockedNAV
            : ((intent.lockedNAV - currentNAV) * 10000) / intent.lockedNAV;

        // If NAV deviated >0.5%, use current NAV (better for user)
        if (navDeviation > 50) {
            navToUse = currentNAV;
        }

        // Recalculate with final NAV
        uint256 depositAmountNormalized = _normalizeAmount(
            intent.depositAmount,
            stablecoins[intent.depositAsset].decimals
        );

        uint256 depositValueUSD = _getStablecoinValue(
            intent.depositAsset,
            depositAmountNormalized
        );

        uint256 feeAmountUSD = (depositValueUSD * mintFeeBps) / BPS_DENOMINATOR;
        uint256 netDepositValue = depositValueUSD - feeAmountUSD;

        shieldMinted = (netDepositValue * PRECISION) / navToUse;

        // Update intent
        intent.actualShield = shieldMinted;
        intent.status = IntentStatus.Completed;

        totalMinted += shieldMinted;
        totalIntentsCompleted++;

        // Mint SHIELD to user
        _mint(intent.user, shieldMinted);

        // Mint fee to treasury
        if (address(treasury) != address(0) && feeAmountUSD > 0) {
            uint256 feeInShield = (feeAmountUSD * PRECISION) / navToUse;
            _mint(address(treasury), feeInShield);
            treasury.notifyFeeCollection(feeInShield, "mint");
            totalFeesCollected += feeInShield;
        }

        emit MintIntentExecuted(
            intentId,
            intent.user,
            shieldMinted,
            navToUse,
            depositId
        );

        return shieldMinted;
    }

    /**
     * @notice Refund expired or failed mint intent
     * @dev Callable by user (if expired) or MINTER_ROLE (if failed)
     * @param intentId Intent identifier
     * @param reason Reason for refund
     */
    function refundMintIntent(
        bytes32 intentId,
        string calldata reason
    ) external nonReentrant {
        MintIntent storage intent = mintIntents[intentId];

        require(intent.user != address(0), "Intent not found");
        require(
            intent.status == IntentStatus.Pending ||
                intent.status == IntentStatus.Processing,
            "Intent not refundable"
        );

        // Only user can refund if expired, or MINTER_ROLE can refund anytime
        if (msg.sender == intent.user) {
            require(block.timestamp > intent.expiresAt, "Intent not expired");
        } else {
            require(hasRole(MINTER_ROLE, msg.sender), "Unauthorized");
        }

        // Mark as refunded
        intent.status = IntentStatus.Refunded;
        totalIntentsRefunded++;

        // Refund stablecoin to user
        IERC20(intent.depositAsset).safeTransfer(
            intent.user,
            intent.depositAmount
        );

        // Refund execution fee
        if (intent.executionFee > 0) {
            (bool success, ) = intent.user.call{value: intent.executionFee}("");
            require(success, "ETH refund failed");
        }

        emit MintIntentRefunded(
            intentId,
            intent.user,
            intent.depositAmount,
            reason
        );
    }

    // ═══════════════════════════════════════════════════════════
    // INTENT-BASED REDEEM FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Create redeem intent (Step 1: User creates intent)
     * @dev User locks SHIELD tokens and creates pending intent
     * @param shieldAmount Amount of SHIELD to redeem
     * @param outputAsset Stablecoin to receive
     * @return intentId Unique identifier for this intent
     */
    function createRedeemIntent(
        uint256 shieldAmount,
        address outputAsset
    ) external payable nonReentrant whenNotPaused returns (bytes32 intentId) {
        // ═══════════════════════════════════════════════════════════
        // CHECKS
        // ═══════════════════════════════════════════════════════════

        if (basketManager == address(0)) revert BasketManagerNotSet();
        if (msg.value > MAX_EXECUTION_FEE) revert ExecutionFeeTooHigh();

        StablecoinConfig memory stablecoin = stablecoins[outputAsset];
        if (!stablecoin.isActive) revert StablecoinNotSupported();
        if (shieldAmount < MIN_REDEEM_AMOUNT) revert BelowMinimumRedeem();
        if (balanceOf(msg.sender) < shieldAmount)
            revert("Insufficient SHIELD balance");

        //  redemption delay checks
        UserRedemption storage userRedeem = userRedemptions[msg.sender];

        if (block.timestamp >= globalRedemptions.lastResetTime + 1 days) {
            globalRedemptions.lastResetTime = block.timestamp;
            globalRedemptions.totalVolumeToday = 0;
            globalRedemptions.uniqueRedeemersToday = 0;
        }

        bool isNewRedeemer = !globalRedemptions.hasRedeemedToday[msg.sender];
        if (isNewRedeemer) {
            globalRedemptions.uniqueRedeemersToday++;
            globalRedemptions.hasRedeemedToday[msg.sender] = true;
        }

        uint256 requiredDelay = REDEMPTION_DELAY;
        if (globalRedemptions.uniqueRedeemersToday > 10) {
            requiredDelay = REDEMPTION_DELAY * 2;
        }
        if (!isNewRedeemer && userRedeem.amountRedeemedToday > 0) {
            requiredDelay = REDEMPTION_DELAY * 3;
        }

        if (block.timestamp < userRedeem.lastRedemptionTime + requiredDelay) {
            revert RedemptionDelayActive();
        }

        // Check daily limit
        if (block.timestamp >= dailyRedemptionResetTime + 1 days) {
            dailyRedemptionResetTime = block.timestamp;
            totalRedeemedToday = 0;
        }

        uint256 maxDailyRedemption = (totalSupply() *
            DAILY_REDEMPTION_LIMIT_BPS) / BPS_DENOMINATOR;
        if (totalRedeemedToday + shieldAmount > maxDailyRedemption) {
            revert ExceedsRedemptionLimit();
        }

        // Lock NAV
        uint256 navPerToken = _getCurrentNAV();
        if (navPerToken == 0) revert InvalidNAV();

        // Calculate expected output
        uint256 redemptionValueUSD = (shieldAmount * navPerToken) / PRECISION;
        uint256 feeAmountUSD = (redemptionValueUSD * redeemFeeBps) /
            BPS_DENOMINATOR;
        uint256 netRedemptionValue = redemptionValueUSD - feeAmountUSD;
        uint256 expectedStablecoin = _denormalizeAmount(
            netRedemptionValue,
            stablecoin.decimals
        );

        if (expectedStablecoin == 0) revert BelowMinimumRedeem();

        // ═══════════════════════════════════════════════════════════
        // EFFECTS
        // ═══════════════════════════════════════════════════════════

        intentId = keccak256(
            abi.encodePacked(
                msg.sender,
                shieldAmount,
                outputAsset,
                block.timestamp,
                block.number,
                totalIntentsCreated
            )
        );

        redeemIntents[intentId] = RedeemIntent({
            intentId: intentId,
            user: msg.sender,
            outputAsset: outputAsset,
            shieldAmount: shieldAmount,
            lockedNAV: navPerToken,
            expectedStablecoin: expectedStablecoin,
            actualStablecoin: 0,
            executionFee: msg.value,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + INTENT_EXPIRY,
            status: IntentStatus.Pending
        });

        userRedeemIntents[msg.sender].push(intentId);
        totalIntentsCreated++;

        // Update redemption tracking
        totalRedeemedToday += shieldAmount;
        globalRedemptions.totalVolumeToday += shieldAmount;
        userRedeem.lastRedemptionTime = block.timestamp;
        userRedeem.amountRedeemedToday += shieldAmount;

        // ═══════════════════════════════════════════════════════════
        // INTERACTIONS
        // ═══════════════════════════════════════════════════════════

        // Transfer SHIELD from user to vault (held until execution)
        _transfer(msg.sender, address(this), shieldAmount);

        emit RedeemIntentCreated(
            intentId,
            msg.sender,
            outputAsset,
            shieldAmount,
            navPerToken,
            expectedStablecoin,
            msg.value,
            block.timestamp + INTENT_EXPIRY
        );

        return intentId;
    }

    /**
     * @notice Execute redeem intent (Step 2: Backend executes after GMX position closure)
     * @dev Only callable by REDEEMER_ROLE (backend service)
     * @param intentId Intent identifier
     */
    function executeRedeemIntent(
        bytes32 intentId
    )
        external
        onlyRole(REDEEMER_ROLE)
        nonReentrant
        returns (uint256 stablecoinReceived)
    {
        RedeemIntent storage intent = redeemIntents[intentId];

        require(intent.user != address(0), "Intent not found");
        require(intent.status == IntentStatus.Pending, "Intent not pending");
        require(block.timestamp <= intent.expiresAt, "Intent expired");

        intent.status = IntentStatus.Processing;

        // Get current NAV
        uint256 currentNAV = _getCurrentNAV();
        uint256 navToUse = intent.lockedNAV;

        uint256 navDeviation = currentNAV > intent.lockedNAV
            ? ((currentNAV - intent.lockedNAV) * 10000) / intent.lockedNAV
            : ((intent.lockedNAV - currentNAV) * 10000) / intent.lockedNAV;

        if (navDeviation > 50) {
            navToUse = currentNAV;
        }

        // Recalculate output
        uint256 redemptionValueUSD = (intent.shieldAmount * navToUse) /
            PRECISION;
        uint256 feeAmountUSD = (redemptionValueUSD * redeemFeeBps) /
            BPS_DENOMINATOR;
        uint256 netRedemptionValue = redemptionValueUSD - feeAmountUSD;

        stablecoinReceived = _denormalizeAmount(
            netRedemptionValue,
            stablecoins[intent.outputAsset].decimals
        );

        intent.actualStablecoin = stablecoinReceived;
        intent.status = IntentStatus.Completed;

        totalRedeemed += intent.shieldAmount;
        totalIntentsCompleted++;

        // Burn SHIELD tokens (held in vault)
        _burn(address(this), intent.shieldAmount);

        // Mint fee to treasury
        if (address(treasury) != address(0) && feeAmountUSD > 0) {
            uint256 feeInShield = (feeAmountUSD * PRECISION) / navToUse;
            _mint(address(treasury), feeInShield);
            treasury.notifyFeeCollection(feeInShield, "redeem");
            totalFeesCollected += feeInShield;
        }

        // Request BasketManager to send stablecoin to user
        // (BasketManager will close GMX positions if needed)
        IBasketManager(basketManager).withdrawReserves{
            value: intent.executionFee
        }(intent.outputAsset, stablecoinReceived, intent.user);

        emit RedeemIntentExecuted(
            intentId,
            intent.user,
            stablecoinReceived,
            navToUse
        );

        return stablecoinReceived;
    }

    /**
     * @notice Refund expired or failed redeem intent
     * @param intentId Intent identifier
     * @param reason Reason for refund
     */
    function refundRedeemIntent(
        bytes32 intentId,
        string calldata reason
    ) external nonReentrant {
        RedeemIntent storage intent = redeemIntents[intentId];

        require(intent.user != address(0), "Intent not found");
        require(
            intent.status == IntentStatus.Pending ||
                intent.status == IntentStatus.Processing,
            "Intent not refundable"
        );

        if (msg.sender == intent.user) {
            require(block.timestamp > intent.expiresAt, "Intent not expired");
        } else {
            require(hasRole(REDEEMER_ROLE, msg.sender), "Unauthorized");
        }

        intent.status = IntentStatus.Refunded;
        totalIntentsRefunded++;

        // Return SHIELD to user
        _transfer(address(this), intent.user, intent.shieldAmount);

        // Refund execution fee
        if (intent.executionFee > 0) {
            (bool success, ) = intent.user.call{value: intent.executionFee}("");
            require(success, "ETH refund failed");
        }

        emit RedeemIntentRefunded(
            intentId,
            intent.user,
            intent.shieldAmount,
            reason
        );
    }

    /**
     * @notice Collect management fee with fractional accumulation
     *  Prevents rounding to zero for small amounts
     */
    function collectManagementFee()
        external
        onlyRole(FEE_MANAGER_ROLE)
        returns (uint256 feeCollected)
    {
        if (address(treasury) == address(0)) return 0;
        if (managementFeeBps == 0) return 0;

        uint256 timeElapsed = block.timestamp - lastManagementFeeCollection;
        if (timeElapsed == 0) return 0;

        uint256 supply = totalSupply();
        if (supply == 0) return 0;

        //  Calculate fee in high precision (wei)
        uint256 feeInWei = (supply * managementFeeBps * timeElapsed * 1e18) /
            (BPS_DENOMINATOR * 365 days);

        // Add to accumulated fractional fees
        accumulatedFractionalFees += feeInWei;

        emit FractionalFeeAccumulated(
            accumulatedFractionalFees,
            FRACTIONAL_FEE_THRESHOLD
        );

        // Only mint if we have enough for at least 0.001 SHIELD
        if (accumulatedFractionalFees >= FRACTIONAL_FEE_THRESHOLD) {
            feeCollected = accumulatedFractionalFees / 1e18; // Convert to SHIELD
            uint256 remainderWei = accumulatedFractionalFees % 1e18;

            accumulatedFractionalFees = remainderWei; // Keep remainder for next time
            lastManagementFeeCollection = block.timestamp;
            totalFeesCollected += feeCollected;

            if (feeCollected > 0) {
                _mint(address(treasury), feeCollected);
                treasury.notifyFeeCollection(feeCollected, "management");
                emit ManagementFeeCollected(feeCollected, block.timestamp);
            }
        } else {
            // Update timestamp even if no fee minted (prevents accumulation gaps)
            lastManagementFeeCollection = block.timestamp;
        }

        return feeCollected;
    }

    // ═══════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Check if BasketManager has capital awaiting GMX deployment
     * @return needsDeployment True if capital needs deployment
     * @return pendingAmount Amount of USDC pending deployment
     */
    function checkPendingDeployment()
        external
        view
        returns (bool needsDeployment, uint256 pendingAmount)
    {
        if (basketManager == address(0)) return (false, 0);

        try IBasketManager(basketManager).needsDeployment() returns (
            bool needs,
            uint256 amount
        ) {
            return (needs, amount);
        } catch {
            return (false, 0);
        }
    }

    /**
     * @notice Get total value managed by BasketManager (GMX positions + reserves)
     * @return totalValue Total value in USD (18 decimals)
     */
    function getTotalManagedValue() external view returns (uint256 totalValue) {
        if (basketManager == address(0)) return 0;

        try IBasketManager(basketManager).getTotalManagedValue() returns (
            uint256 value
        ) {
            return value;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Get current NAV per SHIELD token
     * @return navPerToken NAV in USD (18 decimals)
     */
    function getNAVPerToken() external view returns (uint256 navPerToken) {
        return _getCurrentNAV();
    }

    /**
     *  View function to check accumulated fractional fees
     */
    function getPendingManagementFee()
        external
        view
        returns (uint256 pendingFee, uint256 fractionalWei)
    {
        if (address(treasury) == address(0) || managementFeeBps == 0) {
            return (0, accumulatedFractionalFees);
        }

        uint256 timeElapsed = block.timestamp - lastManagementFeeCollection;
        uint256 supply = totalSupply();

        if (timeElapsed == 0 || supply == 0) {
            return (0, accumulatedFractionalFees);
        }

        uint256 newFeeInWei = (supply * managementFeeBps * timeElapsed * 1e18) /
            (BPS_DENOMINATOR * 365 days);

        uint256 totalWei = accumulatedFractionalFees + newFeeInWei;

        return (totalWei / 1e18, totalWei % 1e18);
    }

    /**
     * @notice Preview mint output
     * @param depositAsset Stablecoin to deposit
     * @param depositAmount Amount to deposit
     * @return shieldOut Estimated SHIELD tokens to receive
     * @return feeAmount Estimated fee in USD
     */
    function previewMint(
        address depositAsset,
        uint256 depositAmount
    ) external view returns (uint256 shieldOut, uint256 feeAmount) {
        StablecoinConfig memory stablecoin = stablecoins[depositAsset];
        if (!stablecoin.isActive) return (0, 0);

        uint256 navPerToken = _getCurrentNAV();
        if (navPerToken == 0) return (0, 0);

        uint256 depositAmountNormalized = _normalizeAmount(
            depositAmount,
            stablecoin.decimals
        );
        uint256 depositValueUSD = _getStablecoinValue(
            depositAsset,
            depositAmountNormalized
        );

        feeAmount = (depositValueUSD * mintFeeBps) / BPS_DENOMINATOR;
        uint256 netValue = depositValueUSD - feeAmount;

        shieldOut = (netValue * PRECISION) / navPerToken;

        return (shieldOut, feeAmount);
    }

    /**
     * @notice Preview redeem output
     * @param shieldAmount Amount of SHIELD to redeem
     * @param outputAsset Stablecoin to receive
     * @return stablecoinOut Estimated stablecoin to receive
     * @return feeAmount Estimated fee in USD
     */
    function previewRedeem(
        uint256 shieldAmount,
        address outputAsset
    ) external view returns (uint256 stablecoinOut, uint256 feeAmount) {
        StablecoinConfig memory stablecoin = stablecoins[outputAsset];
        if (!stablecoin.isActive) return (0, 0);

        uint256 navPerToken = _getCurrentNAV();
        if (navPerToken == 0) return (0, 0);

        uint256 redemptionValueUSD = (shieldAmount * navPerToken) / PRECISION;

        feeAmount = (redemptionValueUSD * redeemFeeBps) / BPS_DENOMINATOR;
        uint256 netValue = redemptionValueUSD - feeAmount;

        stablecoinOut = _denormalizeAmount(netValue, stablecoin.decimals);

        return (stablecoinOut, feeAmount);
    }

    /**
     * @notice Get protocol statistics
     */
    function getProtocolStats()
        external
        view
        returns (
            uint256 currentSupply,
            uint256 currentNAV,
            uint256 totalValueLocked,
            uint256 totalMintedLifetime,
            uint256 totalRedeemedLifetime,
            uint256 totalFeesLifetime,
            uint256 protocolAge
        )
    {
        currentSupply = totalSupply();
        currentNAV = _getCurrentNAV();
        totalValueLocked = (currentSupply * currentNAV) / PRECISION;
        totalMintedLifetime = totalMinted;
        totalRedeemedLifetime = totalRedeemed;
        totalFeesLifetime = totalFeesCollected;
        protocolAge = block.timestamp - deploymentTime;

        return (
            currentSupply,
            currentNAV,
            totalValueLocked,
            totalMintedLifetime,
            totalRedeemedLifetime,
            totalFeesLifetime,
            protocolAge
        );
    }

    /**
     * @notice Get supported stablecoins
     */
    function getSupportedStablecoins()
        external
        view
        returns (address[] memory)
    {
        return supportedStablecoins;
    }

    /**
     * @notice Check if user can redeem
     * @param user User address
     * @param amount Amount to redeem
     * @return canRedeem True if redemption allowed
     * @return reason Reason if blocked
     */
    function canUserRedeem(
        address user,
        uint256 amount
    ) external view returns (bool canRedeem, string memory reason) {
        if (amount < MIN_REDEEM_AMOUNT) {
            return (false, "Below minimum");
        }

        if (balanceOf(user) < amount) {
            return (false, "Insufficient balance");
        }

        UserRedemption memory userRedeem = userRedemptions[user];

        //  Check enhanced redemption delay
        bool isNewRedeemer = block.timestamp >=
            globalRedemptions.lastResetTime + 1 days ||
            !globalRedemptions.hasRedeemedToday[user];

        uint256 requiredDelay = REDEMPTION_DELAY;

        // If too many unique redeemers today, increase delay
        if (globalRedemptions.uniqueRedeemersToday > 10) {
            requiredDelay = REDEMPTION_DELAY * 2;
        }

        // If user is redeeming again same day, longer delay
        if (!isNewRedeemer && userRedeem.amountRedeemedToday > 0) {
            requiredDelay = REDEMPTION_DELAY * 3;
        }

        if (block.timestamp < userRedeem.lastRedemptionTime + requiredDelay) {
            return (false, "Enhanced redemption delay active");
        }

        uint256 maxDaily = (totalSupply() * DAILY_REDEMPTION_LIMIT_BPS) /
            BPS_DENOMINATOR;
        if (totalRedeemedToday + amount > maxDaily) {
            return (false, "Daily limit exceeded");
        }

        return (true, "");
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Get mint intent details
     */
    function getMintIntent(
        bytes32 intentId
    ) external view returns (MintIntent memory) {
        return mintIntents[intentId];
    }

    /**
     * @notice Get redeem intent details
     */
    function getRedeemIntent(
        bytes32 intentId
    ) external view returns (RedeemIntent memory) {
        return redeemIntents[intentId];
    }

    /**
     * @notice Get user's mint intents
     */
    function getUserMintIntents(
        address user
    ) external view returns (bytes32[] memory) {
        return userMintIntents[user];
    }

    /**
     * @notice Get user's redeem intents
     */
    function getUserRedeemIntents(
        address user
    ) external view returns (bytes32[] memory) {
        return userRedeemIntents[user];
    }

    /**
     * @notice Check if mint intent can be executed
     */
    function canExecuteMintIntent(
        bytes32 intentId
    ) external view returns (bool canExecute, string memory reason) {
        MintIntent memory intent = mintIntents[intentId];

        if (intent.user == address(0)) return (false, "Intent not found");
        if (intent.status != IntentStatus.Pending)
            return (false, "Intent not pending");
        if (block.timestamp > intent.expiresAt)
            return (false, "Intent expired");

        return (true, "");
    }

    /**
     * @notice Check if redeem intent can be executed
     */
    function canExecuteRedeemIntent(
        bytes32 intentId
    ) external view returns (bool canExecute, string memory reason) {
        RedeemIntent memory intent = redeemIntents[intentId];

        if (intent.user == address(0)) return (false, "Intent not found");
        if (intent.status != IntentStatus.Pending)
            return (false, "Intent not pending");
        if (block.timestamp > intent.expiresAt)
            return (false, "Intent expired");

        return (true, "");
    }

    /**
     * @notice Get intent statistics
     */
    function getIntentStats()
        external
        view
        returns (
            uint256 totalCreated,
            uint256 totalCompleted,
            uint256 totalRefunded,
            uint256 successRate
        )
    {
        totalCreated = totalIntentsCreated;
        totalCompleted = totalIntentsCompleted;
        totalRefunded = totalIntentsRefunded;

        if (totalCreated > 0) {
            successRate = (totalCompleted * 10000) / totalCreated; // In BPS
        }

        return (totalCreated, totalCompleted, totalRefunded, successRate);
    }
    /**
     * @dev Get current NAV per token from oracle
     */
    function _getCurrentNAV() internal view returns (uint256) {
        uint256 supply = totalSupply();

        // If no supply yet, return initial NAV (basket value)
        if (supply == 0) {
            // Get initial basket value from BasketManager
            if (basketManager != address(0)) {
                try
                    IBasketManager(basketManager).getTotalManagedValue()
                returns (uint256 totalValue) {
                    // totalValue is in 18 decimals, return as initial NAV
                    return totalValue > 0 ? PRECISION : PRECISION; // Start at $1.00
                } catch {
                    return PRECISION; // Fallback to $1.00
                }
            }

            // Fallback to oracle
            try oracle.getLatestValue() returns (
                uint256 value,
                uint256,
                uint256
            ) {
                return value;
            } catch {
                return PRECISION; // Fallback to $1.00
            }
        }

        // Get NAV per token from oracle
        // NOTE: Oracle MUST query BasketManager.getTotalManagedValue() internally
        try oracle.getNAVPerToken(supply) returns (uint256 nav) {
            return nav;
        } catch {
            // Fallback: Calculate directly if oracle fails
            if (basketManager != address(0)) {
                try
                    IBasketManager(basketManager).getTotalManagedValue()
                returns (uint256 totalValue) {
                    // NAV = Total Value / Supply
                    return (totalValue * PRECISION) / supply;
                } catch {
                    // Fallback to TWAP
                    try oracle.getTWAP(TWAP_WINDOW) returns (uint256 twap) {
                        return twap;
                    } catch {
                        revert InvalidNAV();
                    }
                }
            } else {
                revert InvalidNAV();
            }
        }
    }

    /**
     * @dev Get stablecoin value in USD
     */
    function _getStablecoinValue(
        address stablecoin,
        uint256 amount
    ) internal view returns (uint256) {
        // USDC assumed $1.00
        if (stablecoins[stablecoin].pythPriceId == bytes32(0)) {
            return amount;
        }

        // For USDT/DAI, fetch price from Pyth
        bytes32 priceId = stablecoins[stablecoin].pythPriceId;

        try pyth.getPriceNoOlderThan(priceId, PRICE_MAX_AGE) returns (
            PythStructs.Price memory priceData
        ) {
            if (priceData.price <= 0) return amount; // Fallback to $1

            uint256 price = uint256(uint64(priceData.price));
            uint256 normalizedPrice = _normalizePrice(price, priceData.expo);

            return (amount * normalizedPrice) / PRECISION;
        } catch {
            return amount; // Fallback to $1
        }
    }

    /**
     * @dev Normalize amount to 18 decimals
     */
    function _normalizeAmount(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) {
            return amount * 10 ** (18 - decimals);
        } else {
            return amount / 10 ** (decimals - 18);
        }
    }

    /**
     * @dev Denormalize amount from 18 decimals
     */
    function _denormalizeAmount(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) {
            return amount / 10 ** (18 - decimals);
        } else {
            return amount * 10 ** (decimals - 18);
        }
    }

    /**
     * @dev Normalize Pyth price to 18 decimals
     */
    function _normalizePrice(
        uint256 price,
        int32 expo
    ) internal pure returns (uint256) {
        if (expo >= 0) {
            return price * 10 ** uint32(expo);
        } else {
            uint32 expoAbs = uint32(-expo);
            if (expoAbs >= 18) {
                return price / 10 ** (expoAbs - 18);
            } else {
                return price * 10 ** (18 - expoAbs);
            }
        }
    }

    /**
     * @dev Add stablecoin to supported list
     */
    function _addStablecoin(
        address token,
        bytes32 pythPriceId,
        uint8 decimals
    ) internal {
        stablecoins[token] = StablecoinConfig({
            token: token,
            pythPriceId: pythPriceId,
            decimals: decimals,
            isActive: true
        });

        supportedStablecoins.push(token);

        emit StablecoinAdded(token, pythPriceId, decimals);
    }

    // ═══════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Add supported stablecoin
     */
    function addStablecoin(
        address token,
        bytes32 pythPriceId,
        uint8 decimals
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!stablecoins[token].isActive, "Already supported");
        require(token != address(0), "Invalid token");
        require(decimals > 0 && decimals <= 18, "Invalid decimals");

        _addStablecoin(token, pythPriceId, decimals);
    }

    /**
     * @notice Remove stablecoin support
     */
    function removeStablecoin(
        address token
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(stablecoins[token].isActive, "Not supported");

        stablecoins[token].isActive = false;

        emit StablecoinRemoved(token);
    }

    /**
     * @notice Update fee structure
     * @param newMintFeeBps New mint fee (max 5%)
     * @param newRedeemFeeBps New redeem fee (max 5%)
     * @param newManagementFeeBps New annual management fee (max 2%)
     */
    function updateFees(
        uint256 newMintFeeBps,
        uint256 newRedeemFeeBps,
        uint256 newManagementFeeBps
    ) external onlyRole(FEE_MANAGER_ROLE) {
        require(newMintFeeBps <= MAX_MINT_FEE_BPS, "Mint fee too high");
        require(newRedeemFeeBps <= MAX_REDEEM_FEE_BPS, "Redeem fee too high");
        require(
            newManagementFeeBps <= MAX_MANAGEMENT_FEE_BPS,
            "Management fee too high"
        );

        mintFeeBps = newMintFeeBps;
        redeemFeeBps = newRedeemFeeBps;
        managementFeeBps = newManagementFeeBps;

        emit FeesUpdated(newMintFeeBps, newRedeemFeeBps, newManagementFeeBps);
    }

    /**
     * @notice Set BasketManager contract (holds stablecoin reserves)
     * @param _basketManager BasketManager address
     */
    function setBasketManager(
        address _basketManager
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_basketManager != address(0), "Invalid address");

        address oldManager = basketManager;
        basketManager = _basketManager;

        // Grant BasketManager role for integration
        _grantRole(BASKET_MANAGER_ROLE, _basketManager);

        emit BasketManagerUpdated(oldManager, _basketManager);
    }

    function setTreasury(
        address _treasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_treasury.code.length == 0) revert InvalidTreasuryInterface();

        try ITreasuryController(_treasury).isTreasuryController() returns (
            bool isValid
        ) {
            if (!isValid) revert InvalidTreasuryInterface();
        } catch {
            revert InvalidTreasuryInterface();
        }

        treasury = ITreasuryController(_treasury);
        emit TreasuryUpdated(address(0), _treasury);
    }

    /**
     * @notice Emergency pause (stops mints/redeems)
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
     * @notice Emergency withdraw (recover stuck tokens)
     * @dev Only callable by admin when paused
     * @param token Token to recover
     * @param to Recipient address
     * @param amount Amount to recover
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        require(to != address(0), "Invalid recipient");

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Receive ETH refunds from BasketManager/GMX
     */
    receive() external payable {
        // Accept ETH refunds from execution fee overages
    }
}
