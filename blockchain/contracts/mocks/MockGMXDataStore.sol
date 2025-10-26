// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;


contract MockGMXDataStore {
    mapping(bytes32 => uint256) private uintValues;
    mapping(bytes32 => address) private addressValues;
    mapping(bytes32 => bool) private boolValues;

    constructor() {
        //  Set default max leverage for all markets
        _setDefaultLeverage(
            address(0x0000000000000000000000000000000000000001)
        );
        _setDefaultLeverage(
            address(0x0000000000000000000000000000000000000002)
        );
        _setDefaultLeverage(
            address(0x0000000000000000000000000000000000000003)
        );
    }

    function _setDefaultLeverage(address market) private {
        bytes32 leverageKey = keccak256(abi.encode("MAX_LEVERAGE", market));
        uintValues[leverageKey] = 50 * (10 ** 30); // 50x leverage

        // Also set a global default
        bytes32 globalKey = keccak256(abi.encode("MAX_LEVERAGE"));
        uintValues[globalKey] = 50 * (10 ** 30);
    }

    function setUint(bytes32 key, uint256 value) external {
        uintValues[key] = value;
    }

    function setAddress(bytes32 key, address value) external {
        addressValues[key] = value;
    }

    function setBool(bytes32 key, bool value) external {
        boolValues[key] = value;
    }

    function getUint(bytes32 key) external view returns (uint256) {
        uint256 value = uintValues[key];
        //  Return default leverage if not set
        if (value == 0) {
            bytes32 globalKey = keccak256(abi.encode("MAX_LEVERAGE"));
            value = uintValues[globalKey];
            if (value == 0) {
                return 50 * (10 ** 30); // Default 50x
            }
        }
        return value;
    }

    function getAddress(bytes32 key) external view returns (address) {
        return addressValues[key];
    }

    function getBool(bytes32 key) external view returns (bool) {
        return boolValues[key];
    }
}
