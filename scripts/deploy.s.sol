// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "forge-std/Script.sol";
import "../contracts/proxy.sol";

contract DeployTransparentUpgradeableProxy is Script {
    function run() external {
        vm.startBroadcast();

        address implementationAddress = 0x741888D19ce9DF8b22294188F879BF107dFbC148; // Example
        address adminAddress = 0x9A856fcB5d7F33d19BEa7B6B63e61Ed248eeEE56; // Example
        address entropy = 0x98046Bd286715D3B0BC227Dd7a956b83D8978603;
        address entropyProviderAddress = 0x6CC14824Ea2918f5De5C2f75A9Da968ad4BD6344;
        address adminSignerAddress = 0xE4860D3973802C7C42450D7b9741921C7711D039;

        // Encode the addresses into initData
        bytes memory initData = abi.encode(
            entropy,
            entropyProviderAddress,
            adminSignerAddress
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            implementationAddress,
            adminAddress,
            initData
        );

        vm.stopBroadcast();

        console.log("TransparentUpgradeableProxy deployed to:", address(proxy));
    }
}
