// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MandateVault} from "../src/MandateVault.sol";
import {MockUSD8} from "../src/mocks/MockUSD8.sol";

/// Aevum testnet (chain 44005): points the vault at the real tUSD8.
/// Any other chain (anvil): deploys a MockUSD8 first.
///
///   forge script script/Deploy.s.sol --rpc-url aevum --broadcast --account <keystore-name>
contract Deploy is Script {
    address constant TUSD8_AEVUM = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external returns (MandateVault vault, address token) {
        vm.startBroadcast();
        if (block.chainid == 44005) {
            token = TUSD8_AEVUM;
        } else {
            token = address(new MockUSD8());
        }
        vault = new MandateVault(IERC20(token));
        vm.stopBroadcast();
        console2.log("token        ", token);
        console2.log("MandateVault ", address(vault));
    }
}
