// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ═══════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════

error AlreadyInitialized();
error NotInitialized();
error InvalidPythAddress();
error InvalidComponent();
error InvalidWeight();
error WeightsSumInvalid();
error InvalidWindow();
error NoSnapshots();
error TooManyComponents();
error InvalidPriceId();
error UpdateTooFrequent();
error NoActiveComponents();
error PriceDeviationTooHigh();
error InvalidShieldSupply();
error InvalidSigner();
error UnauthorizedSigner();
error NAVTooStale();
error InvalidSignature();

// ═══════════════════════════════════════════════════════════
// BASKET ORACLE CONTRACT
// ═══════════════════════════════════════════════════════════

contract BasketOracle is ReentrancyGuard, Pausable, AccessControl {
    using Math for uint256;
    using SafeCast for int256;
    using SafeCast for uint256;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Role Constants ─────────────────────────────────────

    bytes32 public constant ORACLE_MANAGER_ROLE =
        keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ─── Protocol Constants ─────────────────────────────────

    uint256 public constant MAX_COMPONENTS = 12;
    uint256 public constant SNAPSHOT_WINDOW = 24 hours;
    uint256 public constant MAX_SNAPSHOTS = 288; // 24h / 5min
    uint256 public constant PRICE_DECIMALS = 18;
    uint256 public constant BPS_DENOMINATOR = 10000;

    // Safety limits
    uint256 public constant MAX_NAV_STALENESS = 5 minutes; // Revert if cache >5 min old
    uint256 public constant MIN_UPDATE_INTERVAL = 20 seconds; // Prevent spam
    uint256 public constant MAX_NAV_DEVIATION_BPS = 1000; // 10% max change per update

    // ─── Immutables ─────────────────────────────────────────

    IPyth public immutable pyth;

    // ─── State Variables ────────────────────────────────────

    struct BasketComponent {
        bytes32 pythPriceId; // Pyth Network price feed ID (for reference)
        uint16 weightBps; // Weight in basis points (10000 = 100%)
        bool isActive; // Can be disabled without removal
    }

    struct BasketSnapshot {
        uint128 value; // Basket NAV (compressed to save gas)
        uint64 timestamp; // Block timestamp
        uint64 confidence; // Aggregate confidence score (scaled)
    }

    // NAV Submission Data
    struct NAVSubmission {
        uint256 navPerToken; // NAV per SHIELD token
        uint256 timestamp; // Submission timestamp
        uint256 totalValue; // Total managed value (for transparency)
        uint256 shieldSupply; // SHIELD supply (for verification)
        address submitter; // Backend address that submitted
        bytes signature; // Backend signature
    }

    // Component storage
    mapping(bytes32 => BasketComponent) public components;
    bytes32[] public componentIds;
    uint256 public totalWeightBps;

    // Circular buffer for gas-efficient snapshots
    BasketSnapshot[MAX_SNAPSHOTS] private snapshots;
    uint256 private snapshotHead; // Current write position
    uint256 private snapshotCount; // Number of valid snapshots

    // ═══════════════════════════════════════════════════════════
    //  OFF-CHAIN NAV STATE
    // ═══════════════════════════════════════════════════════════

    uint256 public cachedNAV; // Current NAV (updated by backend)
    uint256 public cachedNAVTimestamp; // Last update timestamp
    NAVSubmission public lastSubmission; // Full submission details

    // Trusted backend signers
    mapping(address => bool) public trustedSigners;

    // Performance tracking
    uint256 public initialBasketValue; // Starting NAV (set at first update)
    uint256 public deploymentTimestamp; // Contract deployment time

    // Chainlink PoR Integration (Phase 2 - Placeholder for now later can be updated)
    address public chainlinkPoRAdapter;
    bool public porVerificationEnabled;

    // Safety state
    bool public isInitialized;

    // ─── Events ─────────────────────────────────────────────

    event NAVSubmitted(
        uint256 indexed navPerToken,
        uint256 timestamp,
        uint256 totalValue,
        uint256 shieldSupply,
        address indexed submitter
    );

    event TrustedSignerUpdated(address indexed signer, bool trusted);

    event NAVStaleWarning(
        uint256 lastUpdate,
        uint256 currentTime,
        uint256 staleness
    );

    event ComponentAdded(
        bytes32 indexed id,
        bytes32 indexed pythPriceId,
        uint16 weight
    );

    event ComponentWeightAdjusted(
        bytes32 indexed id,
        uint16 oldWeight,
        uint16 newWeight,
        string reason
    );

    event ComponentDeactivated(bytes32 indexed id, string reason);

    event EmergencyPaused(address indexed by, string reason);

    event InitialBasketValueSet(uint256 value, uint256 timestamp);

    event ChainlinkPoRAdapterUpdated(
        address indexed oldAdapter,
        address indexed newAdapter
    );

    event PoRVerificationStatusChanged(bool enabled);

    // ─── Constructor ────────────────────────────────────────

    /**
     * @notice Initialize the oracle
     * @param _pyth Pyth Network contract address (for reference)
     * @param _admin Primary admin address
     */
    constructor(address _pyth, address _admin) {
        if (_pyth == address(0) || _admin == address(0)) {
            revert InvalidPythAddress();
        }

        pyth = IPyth(_pyth);

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ORACLE_MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);

        // Initialize state
        deploymentTimestamp = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Initialize basket with commodity components
     * @dev Sets up basket composition (weights only - no price feeds needed as we migrated after feedback secsion 1)
     */
    function initializeBasket() external onlyRole(ORACLE_MANAGER_ROLE) {
        if (isInitialized) revert AlreadyInitialized();

        // Gold (XAU/USD) - 20%
        _addComponentInternal(
            keccak256("gold"),
            0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43,
            2000
        );

        // Crude Oil WTI (WTI/USD) - 15%
        _addComponentInternal(
            keccak256("oil"),
            0xf9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b,
            1500
        );

        // EUR/USD - 25%
        _addComponentInternal(
            keccak256("eur"),
            0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b,
            2500
        );

        // USD/JPY - 15%
        _addComponentInternal(
            keccak256("jpy"),
            0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52,
            1500
        );

        // Wheat Futures (ZW) - 10%
        _addComponentInternal(
            keccak256("wheat"),
            0x6cca4e3b8073388a57189e5d20e5257d22e45e37ba56f6e31ae71fe7f3789dbe,
            1000
        );

        // Copper Futures (HG) - 15%
        _addComponentInternal(
            keccak256("copper"),
            0x43780679e76a8dcb80c1d33cb3ff0d1da2c3fc689805f7db18cd44d53aadce1c,
            1500
        );

        if (totalWeightBps != BPS_DENOMINATOR) {
            revert WeightsSumInvalid();
        }

        isInitialized = true;
    }

    // ═══════════════════════════════════════════════════════════
    // CORE FUNCTION: SUBMIT NAV (Backend calls this)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Submit pre-calculated NAV from off-chain backend
     * @dev Backend queries GMX Reader off-chain, calculates NAV, submits result
     * @param navPerToken NAV per SHIELD token (18 decimals)
     * @param totalValue Total managed value (for transparency)
     * @param shieldSupply SHIELD token supply (for verification)
     * @param signature Backend signature for verification
     */
    function submitNAV(
        uint256 navPerToken,
        uint256 totalValue,
        uint256 shieldSupply,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (!isInitialized) revert NotInitialized();

        // ─── Signature Verification ───────────────────────────────

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                navPerToken,
                totalValue,
                shieldSupply,
                block.timestamp
            )
        );

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(signature);

        if (!trustedSigners[signer]) {
            revert UnauthorizedSigner();
        }

        // ─── Frequency Limiting ───────────────────────────────────

        if (block.timestamp < cachedNAVTimestamp + MIN_UPDATE_INTERVAL) {
            revert UpdateTooFrequent();
        }

        // ─── Deviation Check (Manipulation Protection) ────────────

        if (cachedNAV > 0) {
            uint256 deviation;

            if (navPerToken > cachedNAV) {
                deviation =
                    ((navPerToken - cachedNAV) * BPS_DENOMINATOR) /
                    cachedNAV;
            } else {
                deviation =
                    ((cachedNAV - navPerToken) * BPS_DENOMINATOR) /
                    cachedNAV;
            }

            // Allow max 10% deviation per update (prevent oracle attacks)
            if (deviation > MAX_NAV_DEVIATION_BPS) {
                revert PriceDeviationTooHigh();
            }
        }

        // ─── Update Cached NAV ────────────────────────────────────

        cachedNAV = navPerToken;
        cachedNAVTimestamp = block.timestamp;

        // Store submission details
        lastSubmission = NAVSubmission({
            navPerToken: navPerToken,
            timestamp: block.timestamp,
            totalValue: totalValue,
            shieldSupply: shieldSupply,
            submitter: msg.sender,
            signature: signature
        });

        // Record snapshot for TWAP
        _recordSnapshot(navPerToken, 1e18); // Max confidence for real GMX positions

        // Set initial basket value if first submission
        if (initialBasketValue == 0) {
            initialBasketValue = navPerToken;
            emit InitialBasketValueSet(navPerToken, block.timestamp);
        }

        emit NAVSubmitted(
            navPerToken,
            block.timestamp,
            totalValue,
            shieldSupply,
            msg.sender
        );
    }

    // ═══════════════════════════════════════════════════════════
    // View FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Get current NAV per SHIELD token
     * @param shieldSupply Current SHIELD supply (for validation)
     * @return navPerToken Current NAV (18 decimals)
     * @dev Off-chain calculation: Backend queries GMX Reader → submitNAV() → cached here
     */
    function getNAVPerToken(
        uint256 shieldSupply
    ) external view returns (uint256 navPerToken) {
        // ─── Initialization Check ─────────────────────────────────

        if (cachedNAVTimestamp == 0) {
            revert NotInitialized();
        }

        // ─── Staleness Check ──────────────────────────────────────

        uint256 staleness = block.timestamp - cachedNAVTimestamp;

        if (staleness > MAX_NAV_STALENESS) {
            revert NAVTooStale();
        }

        // ─── Supply Validation (Optional Security Check) ──────────

        if (shieldSupply > 0 && lastSubmission.shieldSupply > 0) {
            uint256 supplyDiff = shieldSupply > lastSubmission.shieldSupply
                ? shieldSupply - lastSubmission.shieldSupply
                : lastSubmission.shieldSupply - shieldSupply;

            uint256 deviationBps = (supplyDiff * BPS_DENOMINATOR) /
                lastSubmission.shieldSupply;

            // If supply changed >10% since last NAV update, NAV might be stale
            // (Don't revert - backend will update soon via event listener)
            if (deviationBps > 1000) {
                // NAV accuracy reduced - its time to TWAP :)
            }
        }

        // ─── Return Cached NAV  ──────────────────

        return cachedNAV;
    }

    /**
     * @notice Check NAV cache health (for monitoring)
     * @dev Call this from backend to detect stale NAV and emit alerts
     * @return isHealthy True if NAV is fresh (<5 min old)
     * @return staleness Seconds since last update
     * @return supplyDrift Supply change since last NAV update (basis points)
     */
    function checkNAVHealth(
        uint256 currentShieldSupply
    )
        external
        returns (bool isHealthy, uint256 staleness, uint256 supplyDrift)
    {
        if (cachedNAVTimestamp == 0) {
            return (false, type(uint256).max, 0);
        }

        staleness = block.timestamp - cachedNAVTimestamp;

        // Calculate supply drift
        if (currentShieldSupply > 0 && lastSubmission.shieldSupply > 0) {
            uint256 supplyDiff = currentShieldSupply >
                lastSubmission.shieldSupply
                ? currentShieldSupply - lastSubmission.shieldSupply
                : lastSubmission.shieldSupply - currentShieldSupply;

            supplyDrift =
                (supplyDiff * BPS_DENOMINATOR) /
                lastSubmission.shieldSupply;
        }

        if (staleness > MAX_NAV_STALENESS) {
            emit NAVStaleWarning(
                cachedNAVTimestamp,
                block.timestamp,
                staleness
            );
            return (false, staleness, supplyDrift);
        }

        return (true, staleness, supplyDrift);
    }

    /**
     * @notice Get Time-Weighted Average NAV
     * @param window Time window in seconds (max 24 hours)
     * @return twap Time-weighted average basket NAV (18 decimals)
     */
    function getTWAP(uint256 window) external view returns (uint256 twap) {
        if (window > SNAPSHOT_WINDOW) revert InvalidWindow();
        if (snapshotCount == 0) revert NoSnapshots();

        uint256 cutoff = block.timestamp - window;

        uint256 validSnapshots = snapshotCount < MAX_SNAPSHOTS
            ? snapshotCount
            : MAX_SNAPSHOTS;
        uint256 weightedSum;
        uint256 totalWeight;

        uint256 startIndex = snapshotCount < MAX_SNAPSHOTS ? 0 : snapshotHead;

        for (uint256 i = 0; i < validSnapshots; ) {
            uint256 index = (startIndex + i) % MAX_SNAPSHOTS;
            BasketSnapshot memory snap = snapshots[index];

            if (snap.timestamp >= cutoff) {
                uint256 timeWeight = block.timestamp - snap.timestamp;
                weightedSum += uint256(snap.value) * timeWeight;
                totalWeight += timeWeight;
            }

            unchecked {
                ++i;
            }
        }

        if (totalWeight == 0) revert NoSnapshots();

        return weightedSum / totalWeight;
    }

    /**
     * @notice Get latest basket value
     * @return value Current basket NAV
     * @return timestamp Last update timestamp
     * @return confidence Confidence score (always max for GMX positions)
     */
    function getLatestValue()
        external
        view
        returns (uint256 value, uint256 timestamp, uint256 confidence)
    {
        if (cachedNAVTimestamp == 0) revert NotInitialized();

        return (cachedNAV, cachedNAVTimestamp, 1e18); // Max confidence for real positions
    }

    /**
     * @notice Get basket appreciation since inception
     * @return appreciationBps Appreciation in basis points (500 = 5%)
     * @return timeElapsed Seconds since deployment
     * @return annualizedReturn Annualized return in basis points
     */
    function getBasketPerformance()
        external
        view
        returns (
            uint256 appreciationBps,
            uint256 timeElapsed,
            uint256 annualizedReturn
        )
    {
        if (initialBasketValue == 0 || cachedNAV == 0) {
            return (0, 0, 0);
        }

        timeElapsed = block.timestamp - deploymentTimestamp;

        if (cachedNAV > initialBasketValue) {
            appreciationBps =
                ((cachedNAV - initialBasketValue) * BPS_DENOMINATOR) /
                initialBasketValue;
        } else {
            appreciationBps = 0; // Basket depreciated
        }

        // Calculate annualized return
        if (timeElapsed > 0) {
            annualizedReturn = (appreciationBps * 365 days) / timeElapsed;
        }

        return (appreciationBps, timeElapsed, annualizedReturn);
    }

    /**
     * @notice Get last NAV submission details
     * @return Full submission data for transparency
     */
    function getLastSubmission() external view returns (NAVSubmission memory) {
        return lastSubmission;
    }

    /**
     * @notice Get component details
     */
    function getComponent(
        bytes32 id
    )
        external
        view
        returns (bytes32 pythPriceId, uint16 weightBps, bool isActive)
    {
        BasketComponent memory component = components[id];
        return (component.pythPriceId, component.weightBps, component.isActive);
    }

    /**
     * @notice Get all component IDs
     */
    function getComponentIds() external view returns (bytes32[] memory) {
        return componentIds;
    }

    /**
     * @notice Get component weight (for AI agents)
     */
    function getComponentWeight(bytes32 id) external view returns (uint16) {
        return components[id].weightBps;
    }

    /**
     * @notice Check if basket is healthy
     * @return healthy True if NAV cache is fresh (<5 minutes old)
     */
    function isHealthy() external view returns (bool healthy) {
        if (!isInitialized) return false;
        if (cachedNAVTimestamp == 0) return false;

        uint256 staleness = block.timestamp - cachedNAVTimestamp;
        return staleness <= MAX_NAV_STALENESS;
    }

    /**
     * @notice Get NAV cache age in seconds
     */
    function getNAVAge() external view returns (uint256) {
        if (cachedNAVTimestamp == 0) return type(uint256).max;
        return block.timestamp - cachedNAVTimestamp;
    }

    // ═══════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Add/remove trusted signer
     * @param signer Backend address
     * @param trusted True to authorize, false to revoke
     */
    function setTrustedSigner(
        address signer,
        bool trusted
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (signer == address(0)) revert InvalidSigner();

        trustedSigners[signer] = trusted;

        emit TrustedSignerUpdated(signer, trusted);
    }

    /**
     * @notice Adjust component weight (AGENSTS)
     * @param id Component identifier
     * @param newWeightBps New weight in basis points
     * @param reason Explanation for adjustment
     */
    function adjustComponentWeight(
        bytes32 id,
        uint16 newWeightBps,
        string calldata reason
    ) external onlyRole(ORACLE_MANAGER_ROLE) {
        BasketComponent storage component = components[id];
        if (component.pythPriceId == bytes32(0)) revert InvalidComponent();
        if (newWeightBps == 0 || newWeightBps > BPS_DENOMINATOR) {
            revert InvalidWeight();
        }

        uint16 oldWeight = component.weightBps;

        // Update total weight
        totalWeightBps = totalWeightBps - oldWeight + newWeightBps;

        if (totalWeightBps > BPS_DENOMINATOR) {
            revert WeightsSumInvalid();
        }

        component.weightBps = newWeightBps;

        emit ComponentWeightAdjusted(id, oldWeight, newWeightBps, reason);
    }

    /**
     * @notice Deactivate component
     */
    function deactivateComponent(
        bytes32 id,
        string calldata reason
    ) external onlyRole(ORACLE_MANAGER_ROLE) {
        BasketComponent storage component = components[id];
        if (component.pythPriceId == bytes32(0)) revert InvalidComponent();

        component.isActive = false;
        totalWeightBps -= component.weightBps;

        emit ComponentDeactivated(id, reason);
    }

    /**
     * @notice Add new component (expansion)
     */
    function addComponent(
        bytes32 id,
        bytes32 pythPriceId,
        uint16 weightBps
    ) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (componentIds.length >= MAX_COMPONENTS) revert TooManyComponents();
        if (pythPriceId == bytes32(0)) revert InvalidPriceId();
        if (components[id].pythPriceId != bytes32(0))
            revert("Component exists");
        if (weightBps == 0 || weightBps > BPS_DENOMINATOR)
            revert InvalidWeight();

        _addComponentInternal(id, pythPriceId, weightBps);
    }

    // ════════════════════════════════════════════════════════════════════════
    // CHAINLINK PROOF OF RESERVE INTEGRATION (PHASE 2) for now its placeholder
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set Chainlink Proof of Reserve adapter address
     * @param _adapter Address of PoR adapter contract
     * @dev Phase 2: Enables verification of real commodity custody
     */
    function setChainlinkPoRAdapter(
        address _adapter
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldAdapter = chainlinkPoRAdapter;
        chainlinkPoRAdapter = _adapter;

        emit ChainlinkPoRAdapterUpdated(oldAdapter, _adapter);
    }

    /**
     * @notice Enable/disable Proof of Reserve verification
     * @param enabled True to require PoR verification
     * @dev Phase 2: When enabled, minting requires custodian proof
     */
    function setPoRVerificationStatus(
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        porVerificationEnabled = enabled;

        emit PoRVerificationStatusChanged(enabled);
    }

    /**
     * @notice Verify reserves via Chainlink PoR (placeholder)
     * @dev Phase 2: Called before allowing mints when PoR enabled
     * @return verified True if reserves match oracle valuation
     * @return reserveValue Total USD value of verified reserves
     */
    function verifyReservesViaChainlink()
        external
        view
        returns (bool verified, uint256 reserveValue)
    {
        // Phase 1: Return cached NAV (off-chain mode)
        if (!porVerificationEnabled || chainlinkPoRAdapter == address(0)) {
            if (cachedNAVTimestamp == 0) {
                return (false, 0);
            }

            return (true, cachedNAV);
        }

        // Phase 2: Call Chainlink PoR adapter
        // (verified, reserveValue) = IChainlinkPoRAdapter(chainlinkPoRAdapter).verifyReserves();

        return (true, 0); // Placeholder
    }

    /**
     * @notice Emergency pause
     */
    function emergencyPause(
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) {
        _pause();
        emit EmergencyPaused(msg.sender, reason);
    }

    /**
     * @notice Resume after pause
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Add component during initialization
     */
    function _addComponentInternal(
        bytes32 id,
        bytes32 pythPriceId,
        uint16 weightBps
    ) internal {
        components[id] = BasketComponent({
            pythPriceId: pythPriceId,
            weightBps: weightBps,
            isActive: true
        });

        componentIds.push(id);
        totalWeightBps += weightBps;

        emit ComponentAdded(id, pythPriceId, weightBps);
    }

    /**
     * @dev Record snapshot in circular buffer
     * @dev  Atomic write with pre-calculated head position
     */
    function _recordSnapshot(uint256 value, uint256 confidence) internal {
        // Calculate next position atomically
        uint256 newHead = (snapshotHead + 1) % MAX_SNAPSHOTS;

        // Write to CURRENT position (not new position)
        snapshots[snapshotHead] = BasketSnapshot({
            value: uint128(value),
            timestamp: uint64(block.timestamp),
            confidence: uint64(confidence / 1e12) // Scale down to fit uint64
        });

        // Update pointers in same transaction (atomic)
        snapshotHead = newHead;
        if (snapshotCount < MAX_SNAPSHOTS) {
            unchecked {
                ++snapshotCount;
            }
        }
    }
}
