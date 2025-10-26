// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockGMXExchangeRouter {
    address public reader;
    address public usdc;
    uint256 private orderCounter;
    mapping(bytes32 => bool) public pendingOrders;

    event OrderCreated(bytes32 indexed orderKey);
    event MulticallExecuted(uint256 callCount);

    constructor(address _reader, address _usdc) {
        reader = _reader;
        usdc = _usdc;
    }

    function sendTokens(
        address token,
        address receiver,
        uint256 amount
    ) external payable {}

    function sendWnt(address receiver, uint256 amount) external payable {}

    function createOrder(
        bytes calldata params
    ) external payable returns (bytes32) {
        bytes32 orderKey = keccak256(
            abi.encodePacked(
                msg.sender,
                orderCounter++,
                block.timestamp,
                block.number
            )
        );
        pendingOrders[orderKey] = true;

        emit OrderCreated(orderKey);
        return orderKey;
    }

    function cancelOrder(bytes32 key) external payable {
        pendingOrders[key] = false;
    }

    function updateOrder(
        bytes32,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        bool
    ) external payable {
        console.log("updateOrder called");
    }

    // Handle any selector for multicall
    function multicall(
        bytes[] calldata data
    ) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);

        for (uint256 i = 0; i < data.length; i++) {
            if (data[i].length < 4) {
                revert("Data too short");
            }

            bytes4 selector = bytes4(data[i][:4]);

            //  For call 0, check if it's sendTokens
            if (i == 0) {
                console.log("  -> Handling first call (sendTokens)");
                results[i] = "";
            }
            //  For call 1+, assume it's createOrder and return orderKey
            else {
                console.log("  -> Handling order creation call");

                bytes32 orderKey = keccak256(
                    abi.encodePacked(
                        msg.sender,
                        orderCounter++,
                        block.timestamp,
                        block.number,
                        i
                    )
                );
                pendingOrders[orderKey] = true;

                emit OrderCreated(orderKey);

                // Encode the orderKey for return
                results[i] = abi.encode(orderKey);
            }
        }

        emit MulticallExecuted(data.length);
        return results;
    }

    function claimFundingFees(
        address[] memory,
        address[] memory,
        address
    ) external payable returns (uint256[] memory) {
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;
        return fees;
    }

    function claimCollateral(
        address[] memory,
        address[] memory,
        uint256[] memory,
        address
    ) external payable returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        return amounts;
    }

    receive() external payable {}
}
