// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockGMXReader {
    struct Market {
        address marketToken;
        address indexToken;
        address longToken;
        address shortToken;
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

    struct Price {
        uint256 min;
        uint256 max;
    }

    struct MarketPrices {
        Price indexTokenPrice;
        Price longTokenPrice;
        Price shortTokenPrice;
    }

    address public dataStore;
    mapping(address => Market) public markets;
    mapping(bytes32 => Position) public positions;
    mapping(address => mapping(address => Price)) public prices;

    event MarketSet(
        address indexed marketToken,
        address indexToken,
        address longToken,
        address shortToken
    );
    event PositionSet(
        bytes32 indexed positionKey,
        uint256 sizeInUsd,
        uint256 collateralAmount
    );
    event PriceSet(
        address indexed market,
        address indexed token,
        uint256 min,
        uint256 max
    );

    constructor(address _dataStore) {
        dataStore = _dataStore;
    }

    function setMockMarket(
        address marketToken,
        address indexToken,
        address longToken,
        address shortToken
    ) external {
        require(marketToken != address(0), "Invalid market token");
        require(longToken != address(0), "Invalid long token");
        require(shortToken != address(0), "Invalid short token");

        markets[marketToken] = Market({
            marketToken: marketToken,
            indexToken: indexToken,
            longToken: longToken,
            shortToken: shortToken
        });

        emit MarketSet(marketToken, indexToken, longToken, shortToken);
    }

    function setMockPosition(
        bytes32 positionKey,
        Position memory position
    ) external {
        positions[positionKey] = position;
        emit PositionSet(
            positionKey,
            position.sizeInUsd,
            position.collateralAmount
        );
    }

    function setMockPrice(
        address market,
        address token,
        uint256 price
    ) external {
        prices[market][token] = Price({min: price, max: price});
        emit PriceSet(market, token, price, price);
    }

    function getMarket(
        address /* dataStore */,
        address market
    ) external view returns (Market memory) {
        Market memory m = markets[market];
        require(m.marketToken != address(0), "Market not configured");
        return m;
    }

    function getPosition(
        address /* dataStore */,
        bytes32 positionKey
    ) external view returns (Position memory) {
        return positions[positionKey];
    }

    function getMarketPrices(
        address /* dataStore */,
        Market memory market
    ) external view returns (MarketPrices memory) {
        return
            MarketPrices({
                indexTokenPrice: prices[market.marketToken][market.indexToken],
                longTokenPrice: prices[market.marketToken][market.longToken],
                shortTokenPrice: prices[market.marketToken][market.shortToken]
            });
    }

    function getMarketTokenPrice(
        address /* dataStore */,
        Market memory,
        Price memory,
        Price memory,
        Price memory,
        bytes32,
        bool
    ) external pure returns (int256, uint256) {
        return (0, 1e30);
    }

    function getExecutionFee(
        address /* dataStore */,
        uint256 /* estimatedGasLimit */
    ) external pure returns (uint256) {
        // Return a reasonable mock execution fee (0.001 ETH)
        return 0.001 ether;
    }
}
