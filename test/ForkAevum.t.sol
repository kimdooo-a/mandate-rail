// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MandateVault} from "../src/MandateVault.sol";

/// Runs the core flow against a fork of Aevum testnet with the REAL tUSD8 contract.
/// Opt-in (needs network):  AEVUM_FORK=true forge test --match-contract ForkAevum -vv
contract ForkAevumTest is Test {
    IERC20 constant TUSD8 = IERC20(0x456569838f1d43009A91ebA4263147Afd7233483);
    // A tUSD8 holder on Aevum testnet (from the explorer's holder list, 2026-11-21) — used only to
    // fund the forked principal; nothing is sent on the real network.
    address constant HOLDER = 0x94ef5dB164e7BBf4149e298c5588C035Ea8E9C05;

    function test_RealTUSD8_EndToEnd() public {
        if (!vm.envOr("AEVUM_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("aevum");
        assertEq(block.chainid, 44005);

        address principal = makeAddr("principal");
        address agent = makeAddr("agent");
        (address merchant, uint256 mpk) = makeAddrAndKey("merchant");

        vm.prank(HOLDER);
        TUSD8.transfer(principal, 1_000e6);

        MandateVault vault = new MandateVault(TUSD8);
        vm.startPrank(principal);
        TUSD8.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        address[] memory ms = new address[](1);
        ms[0] = merchant;
        uint256 id = vault.createMandate(agent, 200e6, 500e6, 1 days, uint64(block.timestamp + 7 days), 60, ms);
        vm.stopPrank();

        MandateVault.Invoice memory inv = MandateVault.Invoice({
            merchant: merchant,
            payer: principal,
            amount: 123_450000,
            ref: keccak256("INV-FORK-1"),
            dueBy: uint64(block.timestamp + 1 days),
            salt: 1
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mpk, vault.invoiceDigest(inv));
        vm.prank(agent);
        bytes32 rid = vault.pay(id, inv, abi.encodePacked(r, s, v));

        vm.warp(block.timestamp + 61);
        vault.release(rid);
        assertEq(TUSD8.balanceOf(merchant), 123_450000);
        assertEq(TUSD8.balanceOf(address(vault)), 1_000e6 - 123_450000);
    }
}
