// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// ═══════════════════════════════════════════════════════════
// INTERFACES
// ═══════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════

error ZeroAddress();
error InvalidPriceFeedId();
error PriceNotFound();
error PriceTooStale();
error InvalidStalenessThreshold();
error BasketManagerNotSet();
error NoActiveAssets();
error EmergencyPriceExpired();

// ═══════════════════════════════════════════════════════════
// PRICE UPDATER CONTRACT
// ═══════════════════════════════════════════════════════════

contract PriceUpdater is AccessControl, ReentrancyGuard, Pausable {
    // ─── Role Constants ─────────────────────────────────────

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ─── Constants ──────────────────────────────────────────

    uint256 public constant DEFAULT_STALENESS_THRESHOLD = 60; // 60 seconds
    uint256 public constant MAX_STALENESS_THRESHOLD = 3600; // 1 hour
    uint256 public constant PRECISION = 1e18;

    // ─── Immutables ─────────────────────────────────────────

    IPyth public immutable pyth;
    IBasketManager public immutable basketManager;

    // ─── State Variables ────────────────────────────────────

    /// @notice Cached price data for efficient reads
    struct CachedPrice {
        int64 price; // Price with expo applied
        uint64 conf; // Confidence interval
        int32 expo; // Exponent
        uint256 publishTime; // Last update timestamp
        bool exists; // Whether price exists
    }

    /// @notice Asset name → Pyth price feed ID mapping
    mapping(string => bytes32) public assetPriceFeedIds;

    /// @notice Asset name → Cached price mapping
    mapping(string => CachedPrice) public cachedPrices;

    /// @notice List of all tracked assets
    string[] public trackedAssets;

    /// @notice Asset name → index in trackedAssets array
    mapping(string => uint256) public assetIndex;

    /// @notice Staleness threshold (how old prices can be)
    uint256 public stalenessThreshold;

    /// @notice Emergency price override
    mapping(string => bool) public useEmergencyPrice;
    mapping(string => CachedPrice) public emergencyPrices;
    uint256 public emergencyPriceSetAt;

    /// @notice Statistics
    uint256 public totalUpdates;
    uint256 public lastBatchUpdateTime;
    uint256 public successfulUpdates;
    uint256 public failedUpdates;

    // ─── Events ─────────────────────────────────────────────

    event PriceUpdated(
        string indexed assetName,
        bytes32 indexed priceFeedId,
        int64 price,
        uint64 conf,
        int32 expo,
        uint256 publishTime
    );

    event BatchPriceUpdate(
        uint256 assetsUpdated,
        uint256 timestamp,
        uint256 totalFee
    );

    event AssetPriceFeedSet(string indexed assetName, bytes32 priceFeedId);

    event AssetRemoved(string indexed assetName);

    event StalenessThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    event EmergencyPriceSet(
        string indexed assetName,
        int64 price,
        uint256 timestamp
    );

    event EmergencyPriceDisabled(string indexed assetName);

    event PriceUpdateFailed(
        string indexed assetName,
        bytes32 priceFeedId,
        string reason
    );

    // ─── Constructor ────────────────────────────────────────

    /**
     * @notice Initialize PriceUpdater
     * @param _pyth Pyth contract address
     * @param _basketManager BasketManager contract address
     * @param _admin Admin address
     */
    constructor(address _pyth, address _basketManager, address _admin) {
        if (_pyth == address(0)) revert ZeroAddress();
        if (_basketManager == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        pyth = IPyth(_pyth);
        basketManager = IBasketManager(_basketManager);

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);

        // Initialize parameters
        stalenessThreshold = DEFAULT_STALENESS_THRESHOLD;

        // Initialize default price feed IDs for common assets
        _initializeDefaultPriceFeeds();
    }

    // ═══════════════════════════════════════════════════════════
    // CORE FUNCTIONS - PRICE UPDATES
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Update all active basket asset prices
     * @param priceUpdate Encoded price update data from Hermes
     * @dev Only callable by KEEPER_ROLE (backend service)
     *
     * Example usage:
     * 1. Fetch priceUpdate from Hermes API
     * 2. Call this function with the priceUpdate data
     * 3. Prices are cached on-chain for free reads
     */
    function updatePrices(
        bytes[] calldata priceUpdate
    ) external payable onlyRole(KEEPER_ROLE) nonReentrant whenNotPaused {
        // Get active assets from BasketManager
        string[] memory activeAssets = _getActiveAssets();

        if (activeAssets.length == 0) revert NoActiveAssets();

        // Calculate and pay update fee
        uint256 fee = pyth.getUpdateFee(priceUpdate);
        require(msg.value >= fee, "Insufficient fee");

        // Update prices in Pyth contract
        pyth.updatePriceFeeds{value: fee}(priceUpdate);

        uint256 updated = 0;
        uint256 failed = 0;

        // Cache prices for all active assets
        for (uint256 i = 0; i < activeAssets.length; i++) {
            string memory assetName = activeAssets[i];
            bytes32 priceFeedId = assetPriceFeedIds[assetName];

            if (priceFeedId == bytes32(0)) {
                emit PriceUpdateFailed(
                    assetName,
                    priceFeedId,
                    "No price feed ID"
                );
                failed++;
                continue;
            }

            try
                pyth.getPriceNoOlderThan(priceFeedId, stalenessThreshold)
            returns (PythStructs.Price memory priceData) {
                // Cache the price
                cachedPrices[assetName] = CachedPrice({
                    price: priceData.price,
                    conf: priceData.conf,
                    expo: priceData.expo,
                    publishTime: priceData.publishTime,
                    exists: true
                });

                updated++;

                emit PriceUpdated(
                    assetName,
                    priceFeedId,
                    priceData.price,
                    priceData.conf,
                    priceData.expo,
                    priceData.publishTime
                );
            } catch Error(string memory reason) {
                emit PriceUpdateFailed(assetName, priceFeedId, reason);
                failed++;
            } catch {
                emit PriceUpdateFailed(assetName, priceFeedId, "Unknown error");
                failed++;
            }
        }

        // Update statistics
        totalUpdates++;
        lastBatchUpdateTime = block.timestamp;
        successfulUpdates += updated;
        failedUpdates += failed;

        emit BatchPriceUpdate(updated, block.timestamp, fee);

        // Refund excess ETH
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{value: msg.value - fee}("");
            require(success, "Refund failed");
        }
    }

    /**
     * @notice Update single asset price
     * @param assetName Name of asset to update
     * @param priceUpdate Encoded price update data from Hermes
     */
    function updateSinglePrice(
        string calldata assetName,
        bytes[] calldata priceUpdate
    ) external payable onlyRole(KEEPER_ROLE) nonReentrant whenNotPaused {
        bytes32 priceFeedId = assetPriceFeedIds[assetName];
        if (priceFeedId == bytes32(0)) revert InvalidPriceFeedId();

        // Calculate and pay update fee
        uint256 fee = pyth.getUpdateFee(priceUpdate);
        require(msg.value >= fee, "Insufficient fee");

        // Update price in Pyth contract
        pyth.updatePriceFeeds{value: fee}(priceUpdate);

        // Get and cache the price
        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(
            priceFeedId,
            stalenessThreshold
        );

        cachedPrices[assetName] = CachedPrice({
            price: priceData.price,
            conf: priceData.conf,
            expo: priceData.expo,
            publishTime: priceData.publishTime,
            exists: true
        });

        successfulUpdates++;

        emit PriceUpdated(
            assetName,
            priceFeedId,
            priceData.price,
            priceData.conf,
            priceData.expo,
            priceData.publishTime
        );

        // Refund excess ETH
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{value: msg.value - fee}("");
            require(success, "Refund failed");
        }
    }

    // ═══════════════════════════════════════════════════════════
    // VIEW FUNCTIONS - FREE PRICE READS (NO GAS FOR EXTERNAL ACTORS Such as Our Agenets With Different Purposes)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Get cached price for an asset (FREE - no gas cost for external reads)
     * @param assetName Name of the asset (e.g., "Gold", "Oil", "EUR/USD")
     * @return price Price value
     * @return conf Confidence interval
     * @return expo Price exponent
     * @return publishTime Last update timestamp
     *
     * @dev This function is view-only, external actors can call it without gas
     * Returns emergency price if enabled and not expired
     */
    function getPrice(
        string calldata assetName
    )
        external
        view
        returns (int64 price, uint64 conf, int32 expo, uint256 publishTime)
    {
        // Check emergency price override
        if (useEmergencyPrice[assetName]) {
            // Check if emergency price is still valid (max 1 hour)
            if (block.timestamp > emergencyPriceSetAt + 1 hours) {
                revert EmergencyPriceExpired();
            }

            CachedPrice memory emergencyPrice = emergencyPrices[assetName];
            return (
                emergencyPrice.price,
                emergencyPrice.conf,
                emergencyPrice.expo,
                emergencyPrice.publishTime
            );
        }

        CachedPrice memory cached = cachedPrices[assetName];

        if (!cached.exists) revert PriceNotFound();

        // Check staleness
        if (block.timestamp > cached.publishTime + stalenessThreshold) {
            revert PriceTooStale();
        }

        return (cached.price, cached.conf, cached.expo, cached.publishTime);
    }

    /**
     * @notice Get price in USD with 18 decimals (FREE)
     * @param assetName Name of the asset
     * @return priceUSD Price in USD (18 decimals)
     * @return publishTime Last update timestamp
     *
     * @dev Converts Pyth price to standard 18 decimal format
     */
    function getPriceUSD(
        string calldata assetName
    ) external view returns (uint256 priceUSD, uint256 publishTime) {
        (int64 price, , int32 expo, uint256 pubTime) = this.getPrice(assetName);

        // Convert to 18 decimals
        uint256 priceValue = uint256(uint64(price));

        if (expo >= 0) {
            priceUSD = priceValue * (10 ** uint32(expo)) * PRECISION;
        } else {
            uint32 expoAbs = uint32(-expo);
            if (expoAbs >= 18) {
                priceUSD = priceValue / (10 ** (expoAbs - 18));
            } else {
                priceUSD = priceValue * (10 ** (18 - expoAbs));
            }
        }

        return (priceUSD, pubTime);
    }

    /**
     * @notice Get all active asset prices (FREE)
     * @return names Asset names
     * @return prices Prices in USD (18 decimals)
     * @return publishTimes Last update timestamps
     */
    function getAllPrices()
        external
        view
        returns (
            string[] memory names,
            uint256[] memory prices,
            uint256[] memory publishTimes
        )
    {
        string[] memory activeAssets = _getActiveAssets();

        names = new string[](activeAssets.length);
        prices = new uint256[](activeAssets.length);
        publishTimes = new uint256[](activeAssets.length);

        for (uint256 i = 0; i < activeAssets.length; i++) {
            names[i] = activeAssets[i];

            try this.getPriceUSD(activeAssets[i]) returns (
                uint256 priceUSD,
                uint256 pubTime
            ) {
                prices[i] = priceUSD;
                publishTimes[i] = pubTime;
            } catch {
                prices[i] = 0;
                publishTimes[i] = 0;
            }
        }

        return (names, prices, publishTimes);
    }

    /**
     * @notice Get price with staleness check (FREE)
     * @param assetName Asset name
     * @param maxAge Maximum acceptable age in seconds
     * @return priceUSD Price in USD (18 decimals)
     * @return publishTime Last update timestamp
     * @return isStale Whether price exceeds maxAge
     */
    function getPriceWithStalenessCheck(
        string calldata assetName,
        uint256 maxAge
    )
        external
        view
        returns (uint256 priceUSD, uint256 publishTime, bool isStale)
    {
        (uint256 price, uint256 pubTime) = this.getPriceUSD(assetName);

        isStale = block.timestamp > pubTime + maxAge;

        return (price, pubTime, isStale);
    }

    /**
     * @notice Check if asset price exists (FREE)
     * @param assetName Asset name
     * @return exists Whether price exists
     * @return age Age of price in seconds
     */
    function hasPriceFor(
        string calldata assetName
    ) external view returns (bool exists, uint256 age) {
        CachedPrice memory cached = cachedPrices[assetName];

        if (!cached.exists) {
            return (false, 0);
        }

        age = block.timestamp > cached.publishTime
            ? block.timestamp - cached.publishTime
            : 0;

        return (true, age);
    }

    /**
     * @notice Get all tracked assets (FREE)
     */
    function getTrackedAssets() external view returns (string[] memory) {
        return trackedAssets;
    }

    /**
     * @notice Get active assets from BasketManager (FREE)
     */
    function getActiveAssets() external view returns (string[] memory) {
        return _getActiveAssets();
    }

    /**
     * @notice Get update statistics (FREE)
     */
    function getStatistics()
        external
        view
        returns (
            uint256 total,
            uint256 successful,
            uint256 failed,
            uint256 lastUpdate,
            uint256 activeAssetsCount
        )
    {
        string[] memory active = _getActiveAssets();

        return (
            totalUpdates,
            successfulUpdates,
            failedUpdates,
            lastBatchUpdateTime,
            active.length
        );
    }

    // ═══════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Get active assets from BasketManager
     */
    function _getActiveAssets() internal view returns (string[] memory) {
        uint256 basketLength = basketManager.getBasketLength();

        // Count active assets
        uint256 activeCount = 0;
        for (uint256 i = 0; i < basketLength; i++) {
            (, , , , , , , , , bool isActive) = basketManager
                .getBasketAllocation(i);
            if (isActive) activeCount++;
        }

        // Build active assets array
        string[] memory activeAssets = new string[](activeCount);
        uint256 index = 0;

        for (uint256 i = 0; i < basketLength; i++) {
            (, , string memory name, , , , , , , bool isActive) = basketManager
                .getBasketAllocation(i);
            if (isActive) {
                activeAssets[index] = name;
                index++;
            }
        }

        return activeAssets;
    }
    /**
     * @dev Initialize default price feed IDs
     */
    function _initializeDefaultPriceFeeds() internal {
        // Gold (XAU/USD)
        _setPriceFeedId(
            "Gold",
            0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2
        );

        // Oil/WTI (WTI/USD)
        _setPriceFeedId(
            "Oil",
            0xf0d57deca57b3da2fe63a493f4c25925fdfd8edf834b20f93e1f84dbd1504d4a
        );

        // EUR/USD
        _setPriceFeedId(
            "EUR/USD",
            0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b
        );

        // JPY/USD (USD/JPY inverted)
        _setPriceFeedId(
            "JPY/USD",
            0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52
        );

        // Wheat
        _setPriceFeedId(
            "Wheat",
            0x44e71e4a0d0b822b1ebd6f624f76f8bd49e73c7b3d2ee6f6e4b3b3f5e7e3e3e3
        );

        // Copper
        _setPriceFeedId(
            "Copper",
            0x7d3fc6f96b2b8e3e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e
        );
    }

    /**
     * @dev Set price feed ID for an asset
     */
    function _setPriceFeedId(
        string memory assetName,
        bytes32 priceFeedId
    ) internal {
        if (assetPriceFeedIds[assetName] == bytes32(0)) {
            // New asset - add to tracked list
            assetIndex[assetName] = trackedAssets.length;
            trackedAssets.push(assetName);
        }

        assetPriceFeedIds[assetName] = priceFeedId;

        emit AssetPriceFeedSet(assetName, priceFeedId);
    }

    // ═══════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Set price feed ID for an asset
     * @param assetName Asset name
     * @param priceFeedId Pyth price feed ID
     */
    function setPriceFeedId(
        string calldata assetName,
        bytes32 priceFeedId
    ) external onlyRole(ADMIN_ROLE) {
        if (priceFeedId == bytes32(0)) revert InvalidPriceFeedId();
        _setPriceFeedId(assetName, priceFeedId);
    }

    /**
     * @notice Set price feed IDs for multiple assets
     * @param assetNames Array of asset names
     * @param priceFeedIds Array of price feed IDs
     */
    function setBatchPriceFeedIds(
        string[] calldata assetNames,
        bytes32[] calldata priceFeedIds
    ) external onlyRole(ADMIN_ROLE) {
        require(assetNames.length == priceFeedIds.length, "Length mismatch");

        for (uint256 i = 0; i < assetNames.length; i++) {
            if (priceFeedIds[i] != bytes32(0)) {
                _setPriceFeedId(assetNames[i], priceFeedIds[i]);
            }
        }
    }

    /**
     * @notice Update staleness threshold
     * @param newThreshold New threshold in seconds
     */
    function setStalenessThreshold(
        uint256 newThreshold
    ) external onlyRole(ADMIN_ROLE) {
        if (newThreshold == 0 || newThreshold > MAX_STALENESS_THRESHOLD) {
            revert InvalidStalenessThreshold();
        }

        uint256 oldThreshold = stalenessThreshold;
        stalenessThreshold = newThreshold;

        emit StalenessThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @notice Set emergency price for an asset
     * @param assetName Asset name
     * @param price Emergency price
     * @param conf Confidence interval
     * @param expo Price exponent
     */
    function setEmergencyPrice(
        string calldata assetName,
        int64 price,
        uint64 conf,
        int32 expo
    ) external onlyRole(EMERGENCY_ROLE) {
        require(price > 0, "Invalid price");

        emergencyPrices[assetName] = CachedPrice({
            price: price,
            conf: conf,
            expo: expo,
            publishTime: block.timestamp,
            exists: true
        });

        useEmergencyPrice[assetName] = true;
        emergencyPriceSetAt = block.timestamp;

        emit EmergencyPriceSet(assetName, price, block.timestamp);
    }

    /**
     * @notice Disable emergency price for an asset
     * @param assetName Asset name
     */
    function disableEmergencyPrice(
        string calldata assetName
    ) external onlyRole(EMERGENCY_ROLE) {
        useEmergencyPrice[assetName] = false;

        emit EmergencyPriceDisabled(assetName);
    }

    /**
     * @notice Remove asset from tracking
     * @param assetName Asset name
     */
    function removeAsset(
        string calldata assetName
    ) external onlyRole(ADMIN_ROLE) {
        uint256 index = assetIndex[assetName];
        uint256 lastIndex = trackedAssets.length - 1;

        if (index != lastIndex) {
            string memory lastAsset = trackedAssets[lastIndex];
            trackedAssets[index] = lastAsset;
            assetIndex[lastAsset] = index;
        }

        trackedAssets.pop();
        delete assetIndex[assetName];
        delete assetPriceFeedIds[assetName];
        delete cachedPrices[assetName];

        emit AssetRemoved(assetName);
    }

    /**
     * @notice Emergency pause
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Withdraw stuck ETH
     */
    function withdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Transfer failed");
    }

    /**
     * @notice Receive ETH for price updates
     */
    receive() external payable {}
}
