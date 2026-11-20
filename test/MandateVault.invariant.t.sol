// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateVault} from "../src/MandateVault.sol";
import {MockUSD8} from "../src/mocks/MockUSD8.sol";

/// @dev Drives random sequences of deposit / pay / clawback / refund / release / withdraw / time.
contract VaultHandler is Test {
    MandateVault public vault;
    MockUSD8 public usd;
    address public principal = makeAddr("principal");
    address public agent = makeAddr("agent");
    uint256 public merchantPk = 0xA11CE;
    address public merchant;
    uint256 public id;
    bytes32[] public receipts;
    uint256 nonce;

    constructor(MandateVault v, MockUSD8 u) {
        vault = v;
        usd = u;
        merchant = vm.addr(merchantPk);
        usd.mint(principal, 1e15);
        vm.startPrank(principal);
        usd.approve(address(vault), type(uint256).max);
        vault.deposit(1e12);
        address[] memory ms = new address[](1);
        ms[0] = merchant;
        id = vault.createMandate(agent, 500e6, 1_200e6, 1 days, uint64(block.timestamp + 3650 days), 1 hours, ms);
        vm.stopPrank();
    }

    function deposit(uint256 amt) external {
        amt = bound(amt, 0, 1e9);
        vm.prank(principal);
        vault.deposit(amt);
    }

    function withdraw(uint256 amt) external {
        amt = bound(amt, 0, vault.balanceOf(principal));
        vm.prank(principal);
        vault.withdraw(amt);
    }

    function pay(uint256 amt) external {
        amt = bound(amt, 1, 500e6);
        MandateVault.Invoice memory inv = MandateVault.Invoice({
            merchant: merchant,
            payer: principal,
            amount: amt,
            ref: bytes32(nonce),
            dueBy: uint64(block.timestamp + 1 days),
            salt: nonce++
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(merchantPk, vault.invoiceDigest(inv));
        bytes memory sig = abi.encodePacked(r, s, v);
        if (vault.check(id, agent, inv, sig) != MandateVault.Reason.OK) return;
        vm.prank(agent);
        receipts.push(vault.pay(id, inv, sig));
    }

    function clawback(uint256 i) external {
        if (receipts.length == 0) return;
        bytes32 rid = receipts[i % receipts.length];
        (,,,, uint64 releaseAt, MandateVault.Status st,) = vault.payments(rid);
        if (st != MandateVault.Status.Escrowed || block.timestamp >= releaseAt) return;
        vm.prank(principal);
        vault.clawback(rid, "");
    }

    function refund(uint256 i) external {
        if (receipts.length == 0) return;
        bytes32 rid = receipts[i % receipts.length];
        (,,,,, MandateVault.Status st,) = vault.payments(rid);
        if (st != MandateVault.Status.Escrowed) return;
        vm.prank(merchant);
        vault.merchantRefund(rid);
    }

    function releaseAll() external {
        vault.releaseBatch(receipts);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }
}

contract MandateVaultInvariantTest is Test {
    VaultHandler h;
    MandateVault vault;
    MockUSD8 usd;

    function setUp() public {
        vm.warp(1_800_000_000);
        usd = new MockUSD8();
        vault = new MandateVault(usd);
        h = new VaultHandler(vault, usd);
        targetContract(address(h));
    }

    /// Every token the vault holds is accounted for as free balance or escrow — no more, no less.
    function invariant_Solvency() public view {
        assertEq(usd.balanceOf(address(vault)), vault.balanceOf(h.principal()) + vault.escrowedOf(h.principal()));
    }

    /// Spend in the current period never exceeds the budget.
    function invariant_BudgetCap() public view {
        assertLe(1_200e6 - vault.remainingBudget(h.id()), 1_200e6);
        (,,,,,,,, uint128 spent,) = vault.mandates(h.id());
        assertLe(spent, 1_200e6);
    }
}
