// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract ETFProxyFactory is UpgradeableBeacon {
    address[] public proxies;

    event ETFProxyCreated(address etfProxy);

    error InitializationFailed();

    constructor(
        address implementation
    ) UpgradeableBeacon(implementation, msg.sender) {}

    function createETFProxy(
        bytes memory data
    ) external onlyOwner returns (address) {
        BeaconProxy proxy = new BeaconProxy(address(this), data);
        emit ETFProxyCreated(address(proxy));
        proxies.push(address(proxy));
        return address(proxy);
    }

    function upgradeToAndCall(
        address newImplementation,
        bytes memory data
    ) external payable onlyOwner {
        upgradeTo(newImplementation);
        uint256 length = proxies.length;
        for (uint256 i = 0; i < length; i++) {
            (bool success, ) = proxies[i].call(data);
            if (!success) revert InitializationFailed();
        }
    }
}
