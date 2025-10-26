// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
// ═══════════════════════════════════════════════════════════
// GMXV2 Interfaces
// ═══════════════════════════════════════════════════════════
interface IOrderCallbackReceiver {
    function afterOrderExecution(
        bytes32 key,
        EventUtils.EventLogData memory orderData,
        EventUtils.EventLogData memory eventData
    ) external;

    function afterOrderCancellation(
        bytes32 key,
        EventUtils.EventLogData memory orderData,
        EventUtils.EventLogData memory eventData
    ) external;

    function afterOrderFrozen(
        bytes32 key,
        EventUtils.EventLogData memory orderData,
        EventUtils.EventLogData memory eventData
    ) external;
}

interface IExchangeRouter {
    function sendTokens(
        address token,
        address receiver,
        uint256 amount
    ) external payable;

    function sendWnt(address receiver, uint256 amount) external payable;

    function createOrder(
        CreateOrderParams calldata params
    ) external payable returns (bytes32);

    function cancelOrder(bytes32 key) external payable;

    function updateOrder(
        bytes32 key,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 triggerPrice,
        uint256 minOutputAmount,
        uint256 validFromTime,
        bool autoCancel
    ) external payable;

    function multicall(
        bytes[] calldata data
    ) external payable returns (bytes[] memory);

    function claimFundingFees(
        address[] memory markets,
        address[] memory tokens,
        address receiver
    ) external payable returns (uint256[] memory);

    function claimCollateral(
        address[] memory markets,
        address[] memory tokens,
        uint256[] memory timeKeys,
        address receiver
    ) external payable returns (uint256[] memory);
}

interface IReader {
    struct Market {
        address marketToken;
        address indexToken;
        address longToken;
        address shortToken;
    }

    struct Price {
        uint256 min;
        uint256 max;
    }

    struct MarketPrices {
        Price indexTokenPrice;
        Price longTokenPrice;
        Price shortTokenPrice;
    }

    struct Position {
        uint256 sizeInUsd;
        uint256 sizeInTokens;
        uint256 collateralAmount;
        uint256 borrowingFactor;
        uint256 fundingFeeAmountPerSize;
        uint256 longTokenClaimableFundingAmountPerSize;
        uint256 shortTokenClaimableFundingAmountPerSize;
        bool isLong;
        uint256 collateralUsd;
    }

    function getMarket(
        address dataStore,
        address market
    ) external view returns (Market memory);

    function getMarketPrices(
        address dataStore,
        Market memory market
    ) external view returns (MarketPrices memory);

    function getPosition(
        address dataStore,
        bytes32 key
    ) external view returns (Position memory);

    function getExecutionFee(
        address dataStore,
        uint256 estimatedGasLimit
    ) external view returns (uint256);
}

interface IDataStore {
    function getUint(bytes32 key) external view returns (uint256);
    function getAddress(bytes32 key) external view returns (address);
}

interface IBasketManager {
    function notifyOrderExecuted(
        bytes32 orderKey,
        bytes32 positionKey,
        uint256 basketIndex,
        bool isIncrease,
        uint256 executedSize,
        uint256 collateralUsd,
        int256 realizedPnl
    ) external;

    function notifyOrderFailed(
        bytes32 orderKey,
        uint256 basketIndex,
        string calldata reason
    ) external;
}

// ═══════════════════════════════════════════════════════════
//  EventUtils.EventLogData
// ═══════════════════════════════════════════════════════════
library EventUtils {
    struct AddressItem {
        string key;
        address value;
    }

    struct AddressItems {
        AddressItem[] items;
    }

    struct UintItem {
        string key;
        uint256 value;
    }

    struct UintItems {
        UintItem[] items;
    }

    struct IntItem {
        string key;
        int256 value;
    }

    struct IntItems {
        IntItem[] items;
    }

    struct BoolItem {
        string key;
        bool value;
    }

    struct BoolItems {
        BoolItem[] items;
    }

    struct Bytes32Item {
        string key;
        bytes32 value;
    }

    struct Bytes32Items {
        Bytes32Item[] items;
    }

    struct BytesItem {
        string key;
        bytes value;
    }

    struct BytesItems {
        BytesItem[] items;
    }

    struct StringItem {
        string key;
        string value;
    }

    struct StringItems {
        StringItem[] items;
    }

    struct EventLogData {
        AddressItems addressItems;
        UintItems uintItems;
        IntItems intItems;
        BoolItems boolItems;
        Bytes32Items bytes32Items;
        BytesItems bytesItems;
        StringItems stringItems;
    }
}

// ═══════════════════════════════════════════════════════════
// GMXV2 ENUM & STRUCTS
// ═══════════════════════════════════════════════════════════
enum OrderType {
    MarketSwap, // 0
    LimitSwap, // 1
    MarketIncrease, // 2
    LimitIncrease, // 3
    MarketDecrease, // 4
    LimitDecrease, // 5
    StopLossDecrease // 6
}

enum DecreasePositionSwapType {
    NoSwap, // 0
    SwapPnlTokenToCollateralToken, // 1
    SwapCollateralTokenToPnlToken // 2
}

struct CreateOrderParamsAddresses {
    address receiver;
    address cancellationReceiver;
    address callbackContract;
    address uiFeeReceiver;
    address market;
    address initialCollateralToken;
    address[] swapPath;
}

struct CreateOrderParamsNumbers {
    uint256 sizeDeltaUsd;
    uint256 initialCollateralDeltaAmount;
    uint256 triggerPrice;
    uint256 acceptablePrice;
    uint256 executionFee;
    uint256 callbackGasLimit;
    uint256 minOutputAmount;
    uint256 validFromTime;
}

struct CreateOrderParams {
    CreateOrderParamsAddresses addresses;
    CreateOrderParamsNumbers numbers;
    OrderType orderType;
    DecreasePositionSwapType decreasePositionSwapType;
    bool isLong;
    bool shouldUnwrapNativeToken;
    bool autoCancel;
    bool triggerAboveThreshold;
    bytes32 referralCode;
}

// ═══════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════
error ZeroAddress();
error ZeroAmount();
error InvalidMarket();
error InvalidCollateral();
error InsufficientExecutionFee();
error SlippageExceeded();
error LeverageExceeded();
error OrderNotFound();
error Unauthorized();
error RefundFailed();
error TransferFailed();
// ═══════════════════════════════════════════════════════════
// GMXV2PerpWrapper CONTRACT
// ═══════════════════════════════════════════════════════════
contract GMXV2PerpWrapper is
    ReentrancyGuard,
    Pausable,
    AccessControl,
    IOrderCallbackReceiver
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── Role Constants ─────────────────────────────────────
    bytes32 public constant TRADER_ROLE = keccak256("TRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant BASKET_MANAGER_ROLE =
        keccak256("BASKET_MANAGER_ROLE");

    // ─── CONSTANTS ─────────────────────────────────────
    uint256 public constant GMX_USD_PRECISION = 1e30;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant DEFAULT_CALLBACK_GAS_LIMIT = 2_000_000;
    uint256 public constant ESTIMATED_ORDER_GAS = 500_000;
    // ─── Immutables ─────────────────────────────────────
    /// Official GMX V2 contracts
    IExchangeRouter public immutable exchangeRouter;
    address public immutable orderVault;
    IReader public immutable reader;
    IDataStore public immutable dataStore;
    address public immutable orderHandler;

    /// Optional receivers / defaults
    address public uiFeeReceiver;
    address public callbackContract;
    bytes32 public referralCode;
    address public basketManager;

    /// Order tracking (with account for subaccounts)
    struct OrderInfo {
        address creator;
        address account; // Receiver/subaccount
        address market;
        address collateralToken;
        uint256 sizeDeltaUsd;
        uint256 collateralAmount;
        bool isLong;
        bool isIncrease;
        uint256 createdAt;
        bool reconciled;
        uint256 basketIndex;
    }

    mapping(bytes32 => OrderInfo) public orders;
    bytes32[] public activeOrders;
    mapping(bytes32 => uint256) public activeOrderIndex;

    /// Position tracking
    struct PositionInfo {
        address account;
        address market;
        address collateralToken;
        uint256 sizeInUsd;
        uint256 collateralUsd;
        bool isLong;
        uint256 lastUpdated;
        bool open;
    }

    mapping(bytes32 => PositionInfo) public positions;
    bytes32[] public activePositions;
    mapping(bytes32 => uint256) public activePositionIndex;

    uint256 public constant MAX_EVENT_ITEMS = 50;
    uint256 public constant MIN_CALLBACK_GAS = 200_000;

    // ─── Events ─────────────────────────────────────────────
    event OrderCreated(
        bytes32 indexed orderKey,
        address indexed creator,
        address indexed market,
        OrderType orderType,
        uint256 sizeDeltaUsd,
        uint256 collateralUsd,
        bool isLong
    );
    event OrderCancelled(bytes32 indexed orderKey, address indexed caller);
    event OrderReconciled(
        bytes32 indexed orderKey,
        bytes32 indexed positionKey
    );
    event PositionClosed(
        bytes32 indexed positionKey,
        uint256 sizeInUsd,
        int256 realizedPnl
    );
    event ExecutionFeeRefunded(address indexed to, uint256 amount);
    event EmergencyWithdraw(address token, address to, uint256 amount);
    event ClaimedFunds(uint256 fundingFees, uint256 collateral);

    // ═══════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════
    constructor(
        address _exchangeRouter,
        address _orderVault,
        address _reader,
        address _dataStore,
        address _orderHandler,
        address _basketManager,
        address _admin,
        uint8 network // 0 = TEST, 1 = ARBITRUM, 2 = AVALANCHE
    ) {
        if (_exchangeRouter == address(0)) revert ZeroAddress();
        if (_orderVault == address(0)) revert ZeroAddress();
        if (_reader == address(0)) revert ZeroAddress();
        if (_dataStore == address(0)) revert ZeroAddress();
        if (_orderHandler == address(0)) revert ZeroAddress();
        if (_basketManager == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        // Official addresses
        if (network == 1) {
            // ARBITRUM
            require(
                _exchangeRouter == 0x7c68C7866A64FA2160F78Eeae77F8b0F06373D61,
                "Invalid ExchangeRouter for Arbitrum"
            );
            require(
                _orderVault == 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5,
                "Invalid OrderVault for Arbitrum"
            );
            require(
                _reader == 0x38d8f1156E7fA9ef1EFeaF88b55C1697074FE2FA,
                "Invalid Reader for Arbitrum"
            );
            require(
                _dataStore == 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8,
                "Invalid DataStore for Arbitrum"
            );
            require(
                _orderHandler == 0x95C2D962b8E962105EFB8d1EB0016Ede4A918877,
                "Invalid OrderHandler for Arbitrum"
            );
        } else if (network == 2) {
            // AVALANCHE
            require(
                _exchangeRouter == 0x11a71cc9E6F9b0FE7A8Ba7C6b812E8454Facc6EF,
                "Invalid ExchangeRouter for Avalanche"
            );
            require(
                _orderVault == 0xF41F0d0A9A4964D1A98F8Ead2d0a5750dAB15655,
                "Invalid OrderVault for Avalanche"
            );
            require(
                _reader == 0xc102F4925Bd8A2Ab0AB91D850d2dd6853a8724aF,
                "Invalid Reader for Avalanche"
            );
            require(
                _dataStore == 0x0090B2c3abb9d495Da0B9f0d2E60f0827411BCfe,
                "Invalid DataStore for Avalanche"
            );
            require(
                _orderHandler == 0xCD8A3107A66cBeA3b9D69AfF33EE0254A1393f4E,
                "Invalid OrderHandler for Avalanche"
            );
        }
        // else network == 0 (TEST) - skip validation

        exchangeRouter = IExchangeRouter(_exchangeRouter);
        orderVault = _orderVault;
        reader = IReader(_reader);
        dataStore = IDataStore(_dataStore);
        orderHandler = _orderHandler;
        basketManager = _basketManager;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(TRADER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(BASKET_MANAGER_ROLE, _basketManager);
        uiFeeReceiver = address(0);
        callbackContract = address(this);
        referralCode = bytes32(0);
    }

    // ═══════════════════════════════════════════════════════════
    // CallBack Section from GMX
    // ═══════════════════════════════════════════════════════════
    function afterOrderExecution(
        bytes32 key,
        EventUtils.EventLogData memory orderData,
        EventUtils.EventLogData memory eventData
    ) external {
        require(msg.sender == orderHandler, "Unauthorized callback");
        _validateCallbackGas(); // Gas check

        OrderInfo storage orderInfo = orders[key];

        require(!orderInfo.reconciled, "Order already reconciled");

        orderInfo.reconciled = true;
        _removeActiveOrder(key);

        uint256 executedSize = _getUintFromEventData(eventData, "sizeDeltaUsd");
        int256 realizedPnl = _getIntFromEventData(eventData, "pnlUsd");

        bool isAdl = _getBoolFromEventData(eventData, "isAdl"); //  ADL check

        bytes32 positionKey = getPositionKey(
            orderInfo.account, // account (receiver)
            orderInfo.market,
            orderInfo.collateralToken,
            orderInfo.isLong
        );

        // Correct USD calc (prices already 1e30)
        uint256 newCollateralUsd = (orderInfo.collateralAmount *
            _getCollateralPrice(
                orderInfo.market,
                orderInfo.collateralToken,
                orderInfo.isLong
            ).min) / (10 ** _getTokenDecimals(orderInfo.collateralToken));

        if (orderInfo.isIncrease) {
            if (positions[positionKey].open) {
                PositionInfo storage pos = positions[positionKey];
                pos.sizeInUsd += executedSize;
                pos.collateralUsd += newCollateralUsd;
                pos.lastUpdated = block.timestamp;
            } else {
                positions[positionKey] = PositionInfo({
                    account: orderInfo.account,
                    market: orderInfo.market,
                    collateralToken: orderInfo.collateralToken,
                    sizeInUsd: executedSize,
                    collateralUsd: newCollateralUsd,
                    isLong: orderInfo.isLong,
                    lastUpdated: block.timestamp,
                    open: true
                });

                activePositionIndex[positionKey] = activePositions.length;
                activePositions.push(positionKey);
            }

            emit OrderReconciled(key, positionKey);
        } else {
            PositionInfo storage pos = positions[positionKey];
            if (pos.open) {
                pos.sizeInUsd -= executedSize;
                //  Fetch actual remaining collateral from getPosition
                IReader.Position memory actualPos = reader.getPosition(
                    address(dataStore),
                    positionKey
                );
                pos.collateralUsd =
                    (actualPos.collateralAmount *
                        _getCollateralPrice(
                            pos.market,
                            pos.collateralToken,
                            pos.isLong
                        ).min) /
                    (10 ** _getTokenDecimals(pos.collateralToken));
                pos.lastUpdated = block.timestamp;

                if (pos.sizeInUsd == 0) {
                    pos.open = false;
                    _removeActivePosition(positionKey);
                }

                emit PositionClosed(positionKey, executedSize, realizedPnl);
                if (isAdl) emit OrderCancelled(key, orderInfo.creator); // Log ADL
            }

            emit OrderReconciled(key, positionKey);
        }
        //  Notify BasketManager
        try
            IBasketManager(basketManager).notifyOrderExecuted(
                key,
                positionKey,
                orderInfo.basketIndex,
                orderInfo.isIncrease,
                executedSize,
                newCollateralUsd,
                realizedPnl
            )
        {} catch {
            // Log failure but don't revert (defensive)
        }
    }

    function afterOrderCancellation(
        bytes32 key,
        EventUtils.EventLogData memory orderData,
        EventUtils.EventLogData memory eventData
    ) external {
        require(msg.sender == orderHandler, "Unauthorized callback");
        _validateCallbackGas();

        OrderInfo storage orderInfo = orders[key];
        require(!orderInfo.reconciled, "Order already reconciled");

        orderInfo.reconciled = true;
        _removeActiveOrder(key);

        emit OrderCancelled(key, orderInfo.creator);
        try
            IBasketManager(basketManager).notifyOrderFailed(
                key,
                orderInfo.basketIndex,
                "Order cancelled"
            )
        {} catch {
            // Log failure but don't revert
        }
    }

    function afterOrderFrozen(
        bytes32 key,
        EventUtils.EventLogData memory orderData,
        EventUtils.EventLogData memory eventData
    ) external {
        require(msg.sender == orderHandler, "Unauthorized callback");
        _validateCallbackGas();

        OrderInfo storage orderInfo = orders[key];
        require(!orderInfo.reconciled, "Order already reconciled");

        orderInfo.reconciled = true;
        _removeActiveOrder(key);

        string memory reason = _getStringFromEventData(eventData, "reason");
        emit OrderCancelled(key, orderInfo.creator);
        // Notify BasketManager of frozen order
        try
            IBasketManager(basketManager).notifyOrderFailed(
                key,
                orderInfo.basketIndex,
                string(abi.encodePacked("Order frozen: ", reason))
            )
        {} catch {
            // Log failure but don't revert
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Postion Key Helper
    // ═══════════════════════════════════════════════════════════
    function getPositionKey(
        address account,
        address market,
        address collateralToken,
        bool isLong
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(account, market, collateralToken, isLong));
    }

    // ═══════════════════════════════════════════════════════════
    // Open Positon
    // ═══════════════════════════════════════════════════════════
    function openPosition(
        address market,
        address collateralToken,
        uint256 collateralAmount,
        uint256 sizeDeltaUsd,
        bool isLong,
        uint256 maxSlippageBps,
        address[] calldata swapPath,
        address subaccount,
        OrderType orderType, // Support Limit/Stop
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 basketIndex
    )
        external
        payable
        onlyRole(BASKET_MANAGER_ROLE)
        nonReentrant
        whenNotPaused
        returns (bytes32 orderKey)
    {
        // Validation
        if (market == address(0)) revert InvalidMarket();

        if (collateralToken == address(0)) revert InvalidCollateral();

        if (collateralAmount == 0) revert ZeroAmount();

        if (sizeDeltaUsd == 0) revert ZeroAmount();

        if (maxSlippageBps > BPS_DENOMINATOR) revert SlippageExceeded();

        // Prices
        IReader.Market memory mkt = reader.getMarket(
            address(dataStore),
            market
        );
        IReader.MarketPrices memory prices = reader.getMarketPrices(
            address(dataStore),
            mkt
        );

        // USD calc
        uint256 collateralUsdMin = (collateralAmount *
            _getCollateralPrice(market, collateralToken, isLong).min) /
            (10 ** _getTokenDecimals(collateralToken));

        // Leverage check
        bytes32 leverageKey = keccak256(abi.encode("MAX_LEVERAGE", market));
        uint256 maxLeverage = dataStore.getUint(leverageKey);
        if (maxLeverage == 0) maxLeverage = 50 * GMX_USD_PRECISION;

        uint256 leverage = (sizeDeltaUsd * GMX_USD_PRECISION) /
            collateralUsdMin;
        if (leverage > maxLeverage) revert LeverageExceeded();

        // Acceptable price
        uint256 acceptablePrice;
        if (isLong) {
            acceptablePrice =
                (prices.indexTokenPrice.max *
                    (BPS_DENOMINATOR + maxSlippageBps)) /
                BPS_DENOMINATOR;
        } else {
            acceptablePrice =
                (prices.indexTokenPrice.min *
                    (BPS_DENOMINATOR - maxSlippageBps)) /
                BPS_DENOMINATOR;
        }

        uint256 executionFee = reader.getExecutionFee(
            address(dataStore),
            ESTIMATED_ORDER_GAS
        );
        if (msg.value < executionFee) revert InsufficientExecutionFee();

        // Pull collateral
        IERC20(collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );
        _ensureAllowance(
            IERC20(collateralToken),
            address(exchangeRouter),
            collateralAmount
        );

        address receiver = subaccount != address(0) ? subaccount : msg.sender;

        CreateOrderParamsAddresses memory addrs = CreateOrderParamsAddresses({
            receiver: receiver,
            cancellationReceiver: msg.sender,
            callbackContract: callbackContract,
            uiFeeReceiver: uiFeeReceiver,
            market: market,
            initialCollateralToken: collateralToken,
            swapPath: swapPath
        });

        CreateOrderParamsNumbers memory nums = CreateOrderParamsNumbers({
            sizeDeltaUsd: sizeDeltaUsd,
            initialCollateralDeltaAmount: collateralAmount,
            triggerPrice: triggerPrice,
            acceptablePrice: acceptablePrice,
            executionFee: executionFee,
            callbackGasLimit: DEFAULT_CALLBACK_GAS_LIMIT,
            minOutputAmount: 0,
            validFromTime: 0
        });

        CreateOrderParams memory params = CreateOrderParams({
            addresses: addrs,
            numbers: nums,
            orderType: orderType,
            decreasePositionSwapType: DecreasePositionSwapType.NoSwap,
            isLong: isLong,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            triggerAboveThreshold: triggerAboveThreshold,
            referralCode: referralCode
        });

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            exchangeRouter.sendTokens.selector,
            collateralToken,
            orderVault,
            collateralAmount
        );
        calls[1] = abi.encodeWithSelector(
            exchangeRouter.createOrder.selector,
            params
        );

        bytes[] memory results = exchangeRouter.multicall{value: executionFee}(
            calls
        );
        orderKey = abi.decode(results[1], (bytes32));

        orders[orderKey] = OrderInfo({
            creator: msg.sender,
            account: receiver,
            market: market,
            collateralToken: collateralToken,
            sizeDeltaUsd: sizeDeltaUsd,
            collateralAmount: collateralAmount,
            isLong: isLong,
            isIncrease: true,
            createdAt: block.timestamp,
            reconciled: false,
            basketIndex: basketIndex
        });

        activeOrderIndex[orderKey] = activeOrders.length;
        activeOrders.push(orderKey);

        emit OrderCreated(
            orderKey,
            msg.sender,
            market,
            orderType,
            sizeDeltaUsd,
            collateralUsdMin,
            isLong
        );

        // Refund excess
        if (msg.value > executionFee) {
            uint256 refundAmount = msg.value - executionFee;
            (bool ok, ) = msg.sender.call{value: refundAmount}("");
            if (!ok) revert RefundFailed();
            emit ExecutionFeeRefunded(msg.sender, refundAmount);
        }

        return orderKey;
    }

    // ═══════════════════════════════════════════════════════════
    // Close Position
    // ═══════════════════════════════════════════════════════════
    function closePosition(
        bytes32 positionKey,
        uint256 sizeUsdToClose,
        uint256 maxSlippageBps,
        address[] calldata swapPath,
        uint256 withdrawAmount,
        uint256 basketIndex
    )
        external
        payable
        onlyRole(BASKET_MANAGER_ROLE)
        nonReentrant
        whenNotPaused
        returns (bytes32 closeOrderKey)
    {
        if (positionKey == bytes32(0)) revert OrderNotFound();
        if (sizeUsdToClose == 0) revert ZeroAmount();
        if (maxSlippageBps > BPS_DENOMINATOR) revert SlippageExceeded();

        PositionInfo storage pos = positions[positionKey];
        if (!pos.open) revert OrderNotFound();
        if (sizeUsdToClose > pos.sizeInUsd) revert ZeroAmount();

        IReader.Market memory mkt = reader.getMarket(
            address(dataStore),
            pos.market
        );
        IReader.MarketPrices memory prices = reader.getMarketPrices(
            address(dataStore),
            mkt
        );

        uint256 acceptablePrice;
        if (pos.isLong) {
            acceptablePrice =
                (prices.indexTokenPrice.min *
                    (BPS_DENOMINATOR - maxSlippageBps)) /
                BPS_DENOMINATOR;
        } else {
            acceptablePrice =
                (prices.indexTokenPrice.max *
                    (BPS_DENOMINATOR + maxSlippageBps)) /
                BPS_DENOMINATOR;
        }

        uint256 executionFee = reader.getExecutionFee(
            address(dataStore),
            ESTIMATED_ORDER_GAS
        );
        if (msg.value < executionFee) revert InsufficientExecutionFee();

        CreateOrderParamsAddresses memory addrs = CreateOrderParamsAddresses({
            receiver: pos.account,
            cancellationReceiver: address(this),
            callbackContract: callbackContract,
            uiFeeReceiver: uiFeeReceiver,
            market: pos.market,
            initialCollateralToken: pos.collateralToken,
            swapPath: swapPath
        });

        CreateOrderParamsNumbers memory nums = CreateOrderParamsNumbers({
            sizeDeltaUsd: sizeUsdToClose,
            initialCollateralDeltaAmount: withdrawAmount,
            triggerPrice: 0,
            acceptablePrice: acceptablePrice,
            executionFee: executionFee,
            callbackGasLimit: DEFAULT_CALLBACK_GAS_LIMIT,
            minOutputAmount: 0,
            validFromTime: 0
        });

        CreateOrderParams memory params = CreateOrderParams({
            addresses: addrs,
            numbers: nums,
            orderType: OrderType.MarketDecrease,
            decreasePositionSwapType: DecreasePositionSwapType.NoSwap,
            isLong: pos.isLong,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            triggerAboveThreshold: false,
            referralCode: referralCode
        });

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            exchangeRouter.createOrder.selector,
            params
        );

        bytes[] memory results = exchangeRouter.multicall{value: executionFee}(
            calls
        );
        closeOrderKey = abi.decode(results[0], (bytes32));

        orders[closeOrderKey] = OrderInfo({
            creator: msg.sender,
            account: pos.account,
            market: pos.market,
            collateralToken: pos.collateralToken,
            sizeDeltaUsd: sizeUsdToClose,
            collateralAmount: 0,
            isLong: pos.isLong,
            isIncrease: false,
            createdAt: block.timestamp,
            reconciled: false,
            basketIndex: basketIndex
        });

        activeOrderIndex[closeOrderKey] = activeOrders.length;
        activeOrders.push(closeOrderKey);

        emit OrderCreated(
            closeOrderKey,
            msg.sender,
            pos.market,
            OrderType.MarketDecrease,
            sizeUsdToClose,
            0,
            pos.isLong
        );

        // Refund excess
        if (msg.value > executionFee) {
            uint256 refundAmount = msg.value - executionFee;
            (bool ok, ) = msg.sender.call{value: refundAmount}("");
            if (!ok) revert RefundFailed();
            emit ExecutionFeeRefunded(msg.sender, refundAmount);
        }

        return closeOrderKey;
    }

    // ═══════════════════════════════════════════════════════════
    // Cancel Order
    // ═══════════════════════════════════════════════════════════
    function cancelOrder(bytes32 orderKey) external nonReentrant {
        OrderInfo memory o = orders[orderKey];
        if (o.creator == address(0)) revert OrderNotFound();

        if (msg.sender != o.creator && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender))
            revert Unauthorized();

        exchangeRouter.cancelOrder(orderKey);

        _removeActiveOrder(orderKey);
        delete orders[orderKey];

        emit OrderCancelled(orderKey, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    // Claim Funds (Admin Functions)
    // ═══════════════════════════════════════════════════════════
    function claimFunds(
        address[] calldata markets,
        address[] calldata tokens,
        uint256[] calldata timeKeys,
        address receiver
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256[] memory fundingFees = exchangeRouter.claimFundingFees(
            markets,
            tokens,
            receiver
        );
        uint256[] memory collateral = exchangeRouter.claimCollateral(
            markets,
            tokens,
            timeKeys,
            receiver
        );
        emit ClaimedFunds(
            fundingFees.length > 0 ? fundingFees[0] : 0,
            collateral.length > 0 ? collateral[0] : 0
        );
    }

    // ═══════════════════════════════════════════════════════════
    // Emergency Functions
    // ═══════════════════════════════════════════════════════════
    function emergencyWithdrawERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(EMERGENCY_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    function emergencyWithdrawNative(
        address payable to,
        uint256 amount
    ) external onlyRole(EMERGENCY_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit EmergencyWithdraw(address(0), to, amount);
    }

    // ═══════════════════════════════════════════════════════════
    // View Functions
    // ═══════════════════════════════════════════════════════════
    function getActiveOrders() external view returns (bytes32[] memory) {
        return activeOrders;
    }

    function getActivePositions() external view returns (bytes32[] memory) {
        return activePositions;
    }

    function isOrderActive(bytes32 orderKey) external view returns (bool) {
        return
            orders[orderKey].creator != address(0) &&
            !orders[orderKey].reconciled;
    }

    function isPositionOpen(bytes32 positionKey) external view returns (bool) {
        return positions[positionKey].open;
    }

    // ═══════════════════════════════════════════════════════════
    // Internal Functions
    // ═══════════════════════════════════════════════════════════
    function _ensureAllowance(
        IERC20 token,
        address spender,
        uint256 amount
    ) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current < amount) {
            token.safeIncreaseAllowance(spender, amount - current);
        }
    }

    function _getTokenDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    // Proper collateral price with market/token validation
    function _getCollateralPrice(
        address market,
        address collateralToken,
        bool isLong
    ) internal view returns (IReader.Price memory) {
        IReader.Market memory mkt = reader.getMarket(
            address(dataStore),
            market
        );
        if (collateralToken == mkt.longToken) {
            return
                reader.getMarketPrices(address(dataStore), mkt).longTokenPrice;
        } else if (collateralToken == mkt.shortToken) {
            return
                reader.getMarketPrices(address(dataStore), mkt).shortTokenPrice;
        } else {
            revert InvalidCollateral();
        }
    }

    function _validateCallbackGas() internal view {
        require(gasleft() > MIN_CALLBACK_GAS, "Insufficient callback gas");
    }
    function _getUintFromEventData(
        EventUtils.EventLogData memory eventData,
        string memory key
    ) internal pure returns (uint256) {
        //  Enforce maximum array length
        require(
            eventData.uintItems.items.length <= MAX_EVENT_ITEMS,
            "Event data too large"
        );

        for (uint256 i = 0; i < eventData.uintItems.items.length; i++) {
            if (
                keccak256(abi.encodePacked(eventData.uintItems.items[i].key)) ==
                keccak256(abi.encodePacked(key))
            ) {
                return eventData.uintItems.items[i].value;
            }
        }
        return 0;
    }
    function _getIntFromEventData(
        EventUtils.EventLogData memory eventData,
        string memory key
    ) internal pure returns (int256) {
        // Enforce maximum array length
        require(
            eventData.intItems.items.length <= MAX_EVENT_ITEMS,
            "Event data too large"
        );

        for (uint256 i = 0; i < eventData.intItems.items.length; i++) {
            if (
                keccak256(abi.encodePacked(eventData.intItems.items[i].key)) ==
                keccak256(abi.encodePacked(key))
            ) {
                return eventData.intItems.items[i].value;
            }
        }
        return 0;
    }
    function _getBoolFromEventData(
        EventUtils.EventLogData memory eventData,
        string memory key
    ) internal pure returns (bool) {
        //  Enforce maximum array length
        require(
            eventData.boolItems.items.length <= MAX_EVENT_ITEMS,
            "Event data too large"
        );

        for (uint256 i = 0; i < eventData.boolItems.items.length; i++) {
            if (
                keccak256(abi.encodePacked(eventData.boolItems.items[i].key)) ==
                keccak256(abi.encodePacked(key))
            ) {
                return eventData.boolItems.items[i].value;
            }
        }
        return false;
    }

    function _getStringFromEventData(
        EventUtils.EventLogData memory eventData,
        string memory key
    ) internal pure returns (string memory) {
        // Enforce maximum array length
        require(
            eventData.stringItems.items.length <= MAX_EVENT_ITEMS,
            "Event data too large"
        );

        for (uint256 i = 0; i < eventData.stringItems.items.length; i++) {
            if (
                keccak256(
                    abi.encodePacked(eventData.stringItems.items[i].key)
                ) == keccak256(abi.encodePacked(key))
            ) {
                return eventData.stringItems.items[i].value;
            }
        }
        return "";
    }

    function _removeActiveOrder(bytes32 orderKey) internal {
        uint256 idx = activeOrderIndex[orderKey];
        uint256 last = activeOrders.length - 1;
        if (activeOrders.length == 0) return;
        if (idx != last) {
            bytes32 lastKey = activeOrders[last];
            activeOrders[idx] = lastKey;
            activeOrderIndex[lastKey] = idx;
        }
        activeOrders.pop();
        delete activeOrderIndex[orderKey];
    }

    function _removeActivePosition(bytes32 positionKey) internal {
        uint256 idx = activePositionIndex[positionKey];
        uint256 last = activePositions.length - 1;
        if (activePositions.length == 0) return;
        if (idx != last) {
            bytes32 lastKey = activePositions[last];
            activePositions[idx] = lastKey;
            activePositionIndex[lastKey] = idx;
        }
        activePositions.pop();
        delete activePositionIndex[positionKey];
    }
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function emergencyUnpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }
    receive() external payable {}
}
