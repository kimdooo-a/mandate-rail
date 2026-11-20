// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MandateVault} from "../src/MandateVault.sol";
import {MockUSD8} from "../src/mocks/MockUSD8.sol";

/// @dev A merchant that is a smart account: signatures are valid if its owner signed.
contract SmartMerchant is IERC1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address rec,,) = ECDSA.tryRecover(hash, sig);
        return rec == owner ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

contract MandateVaultTest is Test {
    MandateVault vault;
    MockUSD8 usd;

    uint256 constant USD = 1e6;
    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address stranger = makeAddr("stranger");
    address keeper = makeAddr("keeper");
    uint256 merchantPk = 0xA11CE;
    address merchant;
    uint256 otherPk = 0xB0B;
    address other;

    uint256 id;

    function setUp() public {
        vm.warp(1_800_000_000);
        usd = new MockUSD8();
        vault = new MandateVault(usd);
        merchant = vm.addr(merchantPk);
        other = vm.addr(otherPk);

        usd.mint(principal, 10_000 * USD);
        vm.startPrank(principal);
        usd.approve(address(vault), type(uint256).max);
        vault.deposit(5_000 * USD);
        address[] memory ms = new address[](1);
        ms[0] = merchant;
        id = vault.createMandate(agent, uint128(500 * USD), uint128(1_200 * USD), 1 days, uint64(block.timestamp + 30 days), 1 hours, ms);
        vm.stopPrank();
    }

    // ─────────────────────────────────────── helpers

    function _inv(address m, uint256 amount, uint256 salt) internal view returns (MandateVault.Invoice memory) {
        return MandateVault.Invoice({
            merchant: m,
            payer: principal,
            amount: amount,
            ref: keccak256(abi.encode("INV", salt)),
            dueBy: uint64(block.timestamp + 7 days),
            salt: salt
        });
    }

    function _sign(uint256 pk, MandateVault.Invoice memory inv) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, vault.invoiceDigest(inv));
        return abi.encodePacked(r, s, v);
    }

    function _pay(MandateVault.Invoice memory inv, bytes memory sig) internal returns (bytes32) {
        vm.prank(agent);
        return vault.pay(id, inv, sig);
    }

    function _expectReject(MandateVault.Reason r) internal {
        vm.expectRevert(abi.encodeWithSelector(MandateVault.PaymentRejected.selector, r));
    }

    // ─────────────────────────────────────── happy path

    function test_PayEscrowThenKeeperReleases() public {
        MandateVault.Invoice memory inv = _inv(merchant, 300 * USD, 1);
        bytes32 rid = _pay(inv, _sign(merchantPk, inv));

        (,,, uint128 amount, uint64 releaseAt, MandateVault.Status st,) = vault.payments(rid);
        assertEq(amount, 300 * USD);
        assertEq(uint8(st), uint8(MandateVault.Status.Escrowed));
        assertEq(vault.balanceOf(principal), 4_700 * USD);
        assertEq(vault.escrowedOf(principal), 300 * USD);
        assertEq(vault.remainingBudget(id), 900 * USD);

        vm.expectRevert(abi.encodeWithSelector(MandateVault.CoolingOffActive.selector, releaseAt));
        vault.release(rid);

        vm.warp(releaseAt);
        vm.prank(keeper);
        vault.release(rid);
        assertEq(usd.balanceOf(merchant), 300 * USD);
        assertEq(vault.escrowedOf(principal), 0);
        (,,,,, st,) = vault.payments(rid);
        assertEq(uint8(st), uint8(MandateVault.Status.Released));
    }

    function test_ZeroCoolingOffPaysImmediately() public {
        address[] memory ms = new address[](1);
        ms[0] = merchant;
        vm.prank(principal);
        uint256 id2 = vault.createMandate(agent, uint128(100 * USD), uint128(100 * USD), 1 days, uint64(block.timestamp + 1 days), 0, ms);
        MandateVault.Invoice memory inv = _inv(merchant, 40 * USD, 9);
        bytes memory sig = _sign(merchantPk, inv);
        vm.prank(agent);
        vault.pay(id2, inv, sig);
        assertEq(usd.balanceOf(merchant), 40 * USD);
    }

    function test_SmartAccountMerchantViaERC1271() public {
        SmartMerchant sm = new SmartMerchant(merchant);
        vm.prank(principal);
        vault.setMerchant(id, address(sm), true);
        MandateVault.Invoice memory inv = _inv(address(sm), 10 * USD, 3);
        bytes32 rid = _pay(inv, _sign(merchantPk, inv)); // owner key signs for the smart account
        (,, address m,,,,) = vault.payments(rid);
        assertEq(m, address(sm));
    }

    // ─────────────────────────────────────── idempotency

    function test_SameInvoiceCannotBePaidTwice() public {
        MandateVault.Invoice memory inv = _inv(merchant, 100 * USD, 1);
        bytes memory sig = _sign(merchantPk, inv);
        _pay(inv, sig);
        _expectReject(MandateVault.Reason.AlreadySettled);
        _pay(inv, sig);
        assertEq(vault.remainingBudget(id), 1_100 * USD);
    }

    function test_CheckIsTheSamePolicyAsPay() public view {
        MandateVault.Invoice memory inv = _inv(merchant, 100 * USD, 1);
        bytes memory sig = _sign(merchantPk, inv);
        assertEq(uint8(vault.check(id, agent, inv, sig)), uint8(MandateVault.Reason.OK));
        assertEq(uint8(vault.check(id, stranger, inv, sig)), uint8(MandateVault.Reason.NotMandateAgent));
    }

    // ─────────────────────────────────────── every refusal reason

    function test_Reject_UnknownMandate() public {
        MandateVault.Invoice memory inv = _inv(merchant, 1 * USD, 1);
        bytes memory sig = _sign(merchantPk, inv);
        vm.prank(agent);
        _expectReject(MandateVault.Reason.UnknownMandate);
        vault.pay(999, inv, sig);
    }

    function test_Reject_NotAgent() public {
        MandateVault.Invoice memory inv = _inv(merchant, 1 * USD, 1);
        bytes memory sig = _sign(merchantPk, inv);
        vm.prank(stranger);
        _expectReject(MandateVault.Reason.NotMandateAgent);
        vault.pay(id, inv, sig);
    }

    function test_Reject_Revoked() public {
        vm.prank(principal);
        vault.revokeMandate(id);
        MandateVault.Invoice memory inv = _inv(merchant, 1 * USD, 1);
        bytes memory sig = _sign(merchantPk, inv);
        _expectReject(MandateVault.Reason.MandateRevoked);
        _pay(inv, sig);
    }

    function test_Reject_Expired() public {
        vm.warp(block.timestamp + 31 days);
        MandateVault.Invoice memory inv = _inv(merchant, 1 * USD, 1);
        bytes memory sig = _sign(merchantPk, inv);
        _expectReject(MandateVault.Reason.MandateExpired);
        _pay(inv, sig);
    }

    function test_Reject_MerchantNotAllowed() public {
        MandateVault.Invoice memory inv = _inv(other, 1 * USD, 1);
        bytes memory sig = _sign(otherPk, inv);
        _expectReject(MandateVault.Reason.MerchantNotAllowed);
        _pay(inv, sig);
    }

    function test_Reject_WrongPayer() public {
        MandateVault.Invoice memory inv = _inv(merchant, 1 * USD, 1);
        inv.payer = stranger;
        bytes memory sig = _sign(merchantPk, inv);
        _expectReject(MandateVault.Reason.WrongPayer);
        _pay(inv, sig);
    }

    function test_Reject_Overdue() public {
        MandateVault.Invoice memory inv = _inv(merchant, 1 * USD, 1);
        inv.dueBy = uint64(block.timestamp - 1);
        bytes memory sig = _sign(merchantPk, inv);
        _expectReject(MandateVault.Reason.InvoiceOverdue);
        _pay(inv, sig);
    }

    function test_Reject_ZeroAmount() public {
        MandateVault.Invoice memory inv = _inv(merchant, 0, 1);
        bytes memory sig = _sign(merchantPk, inv);
        _expectReject(MandateVault.Reason.ZeroAmount);
        _pay(inv, sig);
    }

    function test_Reject_OverPerPaymentCap() public {
        MandateVault.Invoice memory inv = _inv(merchant, 501 * USD, 1);
        bytes memory sig = _sign(merchantPk, inv);
        _expectReject(MandateVault.Reason.OverPerPaymentCap);
        _pay(inv, sig);
    }

    function test_Reject_OverPeriodBudget_ThenNextPeriodOpens() public {
        for (uint256 i = 1; i <= 2; ++i) {
            MandateVault.Invoice memory ok = _inv(merchant, 500 * USD, i);
            _pay(ok, _sign(merchantPk, ok));
        }
        MandateVault.Invoice memory inv = _inv(merchant, 201 * USD, 3);
        bytes memory sig = _sign(merchantPk, inv);
        _expectReject(MandateVault.Reason.OverPeriodBudget);
        _pay(inv, sig);

        // after the daily window rolls, the same invoice is payable
        vm.warp(block.timestamp + 1 days);
        assertEq(vault.remainingBudget(id), 1_200 * USD);
        _pay(inv, sig);
        assertEq(vault.remainingBudget(id), 999 * USD);
    }

    function test_Reject_InsufficientVaultBalance() public {
        vm.prank(principal);
        vault.withdraw(4_900 * USD);
        MandateVault.Invoice memory inv = _inv(merchant, 101 * USD, 1);
        bytes memory sig = _sign(merchantPk, inv);
        _expectReject(MandateVault.Reason.InsufficientVaultBalance);
        _pay(inv, sig);
    }

    function test_Reject_TamperedAmount() public {
        MandateVault.Invoice memory inv = _inv(merchant, 50 * USD, 1);
        bytes memory sig = _sign(merchantPk, inv);
        inv.amount = 499 * USD; // someone edits the invoice after the merchant signed
        _expectReject(MandateVault.Reason.BadMerchantSignature);
        _pay(inv, sig);
    }

    function test_Reject_SignedByWrongKey() public {
        MandateVault.Invoice memory inv = _inv(merchant, 50 * USD, 1);
        bytes memory sig = _sign(otherPk, inv);
        _expectReject(MandateVault.Reason.BadMerchantSignature);
        _pay(inv, sig);
    }

    // ─────────────────────────────────────── principal controls

    function test_ClawbackDuringCoolingOff() public {
        MandateVault.Invoice memory inv = _inv(merchant, 400 * USD, 1);
        bytes32 rid = _pay(inv, _sign(merchantPk, inv));

        vm.prank(stranger);
        vm.expectRevert(MandateVault.NotPrincipal.selector);
        vault.clawback(rid, "x");

        vm.prank(principal);
        vault.clawback(rid, "duplicate order");
        assertEq(vault.balanceOf(principal), 5_000 * USD);
        assertEq(vault.escrowedOf(principal), 0);
        // budget stays consumed on purpose
        assertEq(vault.remainingBudget(id), 800 * USD);

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(MandateVault.NotEscrowed.selector);
        vault.release(rid);
        // and it can never be re-paid
        bytes memory sig = _sign(merchantPk, inv);
        _expectReject(MandateVault.Reason.AlreadySettled);
        _pay(inv, sig);
    }

    function test_ClawbackTooLate() public {
        MandateVault.Invoice memory inv = _inv(merchant, 400 * USD, 1);
        bytes32 rid = _pay(inv, _sign(merchantPk, inv));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(principal);
        vm.expectRevert(MandateVault.CoolingOffOver.selector);
        vault.clawback(rid, "late");
    }

    function test_MerchantRefund() public {
        MandateVault.Invoice memory inv = _inv(merchant, 100 * USD, 1);
        bytes32 rid = _pay(inv, _sign(merchantPk, inv));
        vm.prank(stranger);
        vm.expectRevert(MandateVault.NotMerchant.selector);
        vault.merchantRefund(rid);
        vm.prank(merchant);
        vault.merchantRefund(rid);
        assertEq(vault.balanceOf(principal), 5_000 * USD);
    }

    function test_EscrowIsNotWithdrawable() public {
        MandateVault.Invoice memory inv = _inv(merchant, 500 * USD, 1);
        _pay(inv, _sign(merchantPk, inv));
        vm.prank(principal);
        vm.expectRevert(MandateVault.InsufficientBalance.selector);
        vault.withdraw(5_000 * USD);
    }

    function test_OnlyPrincipalManagesMandate() public {
        vm.startPrank(stranger);
        vm.expectRevert(MandateVault.NotPrincipal.selector);
        vault.revokeMandate(id);
        vm.expectRevert(MandateVault.NotPrincipal.selector);
        vault.setMerchant(id, stranger, true);
        vm.stopPrank();
    }

    function test_CreateMandateRejectsBadParams() public {
        address[] memory ms = new address[](0);
        vm.startPrank(principal);
        vm.expectRevert(MandateVault.BadParams.selector);
        vault.createMandate(address(0), 1, 1, 1, uint64(block.timestamp + 1), 0, ms);
        vm.expectRevert(MandateVault.BadParams.selector);
        vault.createMandate(agent, 2, 1, 1, uint64(block.timestamp + 1), 0, ms); // budget < cap
        vm.expectRevert(MandateVault.BadParams.selector);
        vault.createMandate(agent, 1, 1, 1, uint64(block.timestamp), 0, ms); // already expired
        vm.expectRevert(MandateVault.BadParams.selector);
        vault.createMandate(agent, 1, 1, 1, uint64(block.timestamp + 1), 31 days, ms);
        vm.stopPrank();
    }

    function test_ReleaseBatchSkipsWhatItCannotRelease() public {
        MandateVault.Invoice memory a = _inv(merchant, 100 * USD, 1);
        bytes32 ra = _pay(a, _sign(merchantPk, a));
        vm.warp(block.timestamp + 30 minutes);
        MandateVault.Invoice memory b = _inv(merchant, 100 * USD, 2);
        bytes32 rb = _pay(b, _sign(merchantPk, b));
        vm.warp(block.timestamp + 31 minutes); // a is releasable, b is not

        bytes32[] memory ids = new bytes32[](3);
        ids[0] = ra;
        ids[1] = rb;
        ids[2] = bytes32(uint256(123)); // unknown receipt
        uint256 n = vault.releaseBatch(ids);
        assertEq(n, 1);
        assertEq(usd.balanceOf(merchant), 100 * USD);
    }

    // ─────────────────────────────────────── fuzz

    /// The agent can never move more than the period budget inside one period,
    /// no matter how it slices the payments.
    function testFuzz_BudgetNeverExceededWithinPeriod(uint256[8] memory amounts) public {
        uint256 spent;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amt = bound(amounts[i], 1, 500 * USD);
            MandateVault.Invoice memory inv = _inv(merchant, amt, 100 + i);
            bytes memory sig = _sign(merchantPk, inv);
            if (spent + amt <= 1_200 * USD) {
                _pay(inv, sig);
                spent += amt;
            } else {
                _expectReject(MandateVault.Reason.OverPeriodBudget);
                _pay(inv, sig);
            }
        }
        assertLe(vault.escrowedOf(principal), 1_200 * USD);
        assertEq(vault.remainingBudget(id), 1_200 * USD - spent);
    }

    function testFuzz_PeriodAlignmentSurvivesIdleGaps(uint32 gap) public {
        vm.warp(block.timestamp + uint256(gap) % (29 days));
        MandateVault.Invoice memory inv = _inv(merchant, 10 * USD, 1);
        _pay(inv, _sign(merchantPk, inv));
        (,,,,,,, uint64 start,,) = vault.mandates(id);
        assertEq((start - 1_800_000_000) % 1 days, 0);
        assertLe(start, block.timestamp);
        assertGt(start + 1 days, block.timestamp);
    }
}
