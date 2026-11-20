// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MandateVault
/// @notice Spending mandates for autonomous purchasing agents, settled in tUSD8.
///
/// A principal (a company treasury, a DAO, a person) parks stablecoin in the vault and
/// grants an agent key a *mandate*: a per-payment cap, a rolling budget per period,
/// an expiry, and an allowlist of merchants. The agent can only move money by
/// presenting an invoice that the merchant signed (EIP-712 / ERC-1271). Every payment
/// first sits in a short escrow ("cooling-off") during which the principal can claw it
/// back; afterwards anyone (a keeper, the merchant) can release it to the merchant.
///
/// Two keys must agree before value moves (agent + merchant), the agent key can never
/// exceed the limits the principal wrote on-chain, and every decision leaves an event.
contract MandateVault is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────── types

    struct Invoice {
        address merchant; // who gets paid (and who signed)
        address payer; // the principal whose vault balance pays
        uint256 amount; // token base units (tUSD8 = 6 decimals)
        bytes32 ref; // merchant's invoice reference (e.g. keccak of "INV-2026-0042")
        uint64 dueBy; // unix seconds; agent may not pay after this
        uint256 salt; // makes otherwise identical invoices distinct
    }

    struct Mandate {
        address principal;
        address agent;
        uint128 perPaymentCap;
        uint128 periodBudget;
        uint64 periodLength; // seconds
        uint64 expiresAt; // unix seconds
        uint64 coolingOff; // seconds a payment waits in escrow
        uint64 periodStart;
        uint128 spentInPeriod;
        bool revoked;
    }

    enum Status {
        None,
        Escrowed,
        Released,
        ClawedBack,
        Refunded
    }

    struct Payment {
        uint256 mandateId;
        address principal;
        address merchant;
        uint128 amount;
        uint64 releaseAt;
        Status status;
        bytes32 ref;
    }

    /// @notice Why a payment would be (or was) refused. `OK` means it would go through.
    enum Reason {
        OK,
        AlreadySettled,
        UnknownMandate,
        NotMandateAgent,
        MandateRevoked,
        MandateExpired,
        MerchantNotAllowed,
        WrongPayer,
        InvoiceOverdue,
        ZeroAmount,
        OverPerPaymentCap,
        OverPeriodBudget,
        InsufficientVaultBalance,
        BadMerchantSignature
    }

    bytes32 public constant INVOICE_TYPEHASH = keccak256(
        "Invoice(address merchant,address payer,uint256 amount,bytes32 ref,uint64 dueBy,uint256 salt)"
    );

    // ─────────────────────────────────────────────────────────── state

    IERC20 public immutable token;

    uint256 public mandateCount;
    mapping(uint256 => Mandate) public mandates;
    mapping(uint256 => mapping(address => bool)) public merchantAllowed;

    /// @notice Free (unallocated) vault balance per principal.
    mapping(address => uint256) public balanceOf;
    /// @notice Tokens currently held in escrow, per principal.
    mapping(address => uint256) public escrowedOf;

    /// @notice Payment record keyed by the EIP-712 digest of the invoice — the receipt id.
    mapping(bytes32 => Payment) public payments;

    // ─────────────────────────────────────────────────────────── events

    event Deposited(address indexed principal, uint256 amount);
    event Withdrawn(address indexed principal, uint256 amount);
    event MandateCreated(
        uint256 indexed mandateId,
        address indexed principal,
        address indexed agent,
        uint128 perPaymentCap,
        uint128 periodBudget,
        uint64 periodLength,
        uint64 expiresAt,
        uint64 coolingOff
    );
    event MerchantSet(uint256 indexed mandateId, address indexed merchant, bool allowed);
    event MandateRevoked(uint256 indexed mandateId);
    event PaymentEscrowed(
        bytes32 indexed receiptId,
        uint256 indexed mandateId,
        address indexed merchant,
        address agent,
        uint256 amount,
        bytes32 ref,
        uint64 releaseAt
    );
    event PaymentReleased(bytes32 indexed receiptId, address indexed merchant, uint256 amount, address releasedBy);
    event PaymentClawedBack(bytes32 indexed receiptId, uint256 amount, string note);
    event PaymentRefunded(bytes32 indexed receiptId, uint256 amount);

    // ─────────────────────────────────────────────────────────── errors

    error PaymentRejected(Reason reason);
    error NotPrincipal();
    error NotMerchant();
    error BadParams();
    error InsufficientBalance();
    error NotEscrowed();
    error CoolingOffOver();
    error CoolingOffActive(uint64 releaseAt);

    constructor(IERC20 token_) EIP712("MandateVault", "1") {
        token = token_;
    }

    // ─────────────────────────────────────────────────────────── principal: funds

    /// @notice Move tokens into your vault balance (approve first).
    function deposit(uint256 amount) external nonReentrant {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before; // robust to fee-on-transfer
        balanceOf[msg.sender] += received;
        emit Deposited(msg.sender, received);
    }

    /// @notice Withdraw unallocated balance. Escrowed payments are not withdrawable.
    function withdraw(uint256 amount) external nonReentrant {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────── principal: mandates

    function createMandate(
        address agent,
        uint128 perPaymentCap,
        uint128 periodBudget,
        uint64 periodLength,
        uint64 expiresAt,
        uint64 coolingOff,
        address[] calldata merchants
    ) external returns (uint256 id) {
        if (
            agent == address(0) || perPaymentCap == 0 || periodBudget < perPaymentCap || periodLength == 0
                || expiresAt <= block.timestamp || coolingOff > 30 days
        ) revert BadParams();

        id = ++mandateCount;
        mandates[id] = Mandate({
            principal: msg.sender,
            agent: agent,
            perPaymentCap: perPaymentCap,
            periodBudget: periodBudget,
            periodLength: periodLength,
            expiresAt: expiresAt,
            coolingOff: coolingOff,
            periodStart: uint64(block.timestamp),
            spentInPeriod: 0,
            revoked: false
        });
        emit MandateCreated(id, msg.sender, agent, perPaymentCap, periodBudget, periodLength, expiresAt, coolingOff);

        for (uint256 i; i < merchants.length; ++i) {
            merchantAllowed[id][merchants[i]] = true;
            emit MerchantSet(id, merchants[i], true);
        }
    }

    function setMerchant(uint256 id, address merchant, bool allowed) external {
        if (mandates[id].principal != msg.sender) revert NotPrincipal();
        merchantAllowed[id][merchant] = allowed;
        emit MerchantSet(id, merchant, allowed);
    }

    /// @notice Instant kill switch. Already-escrowed payments can still be clawed back.
    function revokeMandate(uint256 id) external {
        if (mandates[id].principal != msg.sender) revert NotPrincipal();
        mandates[id].revoked = true;
        emit MandateRevoked(id);
    }

    // ─────────────────────────────────────────────────────────── agent: pay

    /// @notice EIP-712 digest of an invoice. This is also the receipt id.
    function invoiceDigest(Invoice calldata inv) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(INVOICE_TYPEHASH, inv.merchant, inv.payer, inv.amount, inv.ref, inv.dueBy, inv.salt))
        );
    }

    /// @notice Dry-run the full policy for `caller`. Agents call this before paying so they
    ///         can explain refusals in plain language without spending gas.
    function check(uint256 id, address caller, Invoice calldata inv, bytes calldata merchantSig)
        public
        view
        returns (Reason)
    {
        return _check(id, caller, inv, merchantSig, invoiceDigest(inv));
    }

    /// @notice Pay a merchant-signed invoice under mandate `id`. Idempotent per invoice:
    ///         a second attempt for the same invoice reverts with AlreadySettled.
    function pay(uint256 id, Invoice calldata inv, bytes calldata merchantSig)
        external
        nonReentrant
        returns (bytes32 receiptId)
    {
        receiptId = invoiceDigest(inv);
        Reason r = _check(id, msg.sender, inv, merchantSig, receiptId);
        if (r != Reason.OK) revert PaymentRejected(r);

        Mandate storage m = mandates[id];
        _rollPeriod(m);
        uint128 amount = uint128(inv.amount); // _check bounded it by perPaymentCap (uint128)
        m.spentInPeriod += amount;
        balanceOf[m.principal] -= amount;

        uint64 releaseAt = uint64(block.timestamp) + m.coolingOff;
        payments[receiptId] = Payment({
            mandateId: id,
            principal: m.principal,
            merchant: inv.merchant,
            amount: amount,
            releaseAt: releaseAt,
            status: Status.Escrowed,
            ref: inv.ref
        });
        escrowedOf[m.principal] += amount;
        emit PaymentEscrowed(receiptId, id, inv.merchant, msg.sender, amount, inv.ref, releaseAt);

        if (m.coolingOff == 0) _release(receiptId);
    }

    // ─────────────────────────────────────────────────────────── settlement

    /// @notice Release an escrowed payment once its cooling-off is over. Permissionless,
    ///         so a keeper or the merchant can settle without trusting anyone.
    function release(bytes32 receiptId) public nonReentrant {
        Payment storage p = payments[receiptId];
        if (p.status != Status.Escrowed) revert NotEscrowed();
        if (block.timestamp < p.releaseAt) revert CoolingOffActive(p.releaseAt);
        _release(receiptId);
    }

    /// @notice Release many; skips entries that are not yet releasable instead of reverting
    ///         (so one early or already-settled receipt cannot block a keeper batch).
    function releaseBatch(bytes32[] calldata receiptIds) external nonReentrant returns (uint256 released) {
        for (uint256 i; i < receiptIds.length; ++i) {
            Payment storage p = payments[receiptIds[i]];
            if (p.status == Status.Escrowed && block.timestamp >= p.releaseAt) {
                _release(receiptIds[i]);
                ++released;
            }
        }
    }

    /// @notice Principal pulls a payment back while it is still cooling off.
    ///         Budget already consumed is NOT restored: a clawed-back agent should not
    ///         regain spending room by triggering clawbacks.
    function clawback(bytes32 receiptId, string calldata note) external nonReentrant {
        Payment storage p = payments[receiptId];
        if (p.status != Status.Escrowed) revert NotEscrowed();
        if (p.principal != msg.sender) revert NotPrincipal();
        if (block.timestamp >= p.releaseAt) revert CoolingOffOver();
        p.status = Status.ClawedBack;
        escrowedOf[p.principal] -= p.amount;
        balanceOf[p.principal] += p.amount;
        emit PaymentClawedBack(receiptId, p.amount, note);
    }

    /// @notice Merchant voluntarily returns an escrowed payment (e.g. order cancelled).
    function merchantRefund(bytes32 receiptId) external nonReentrant {
        Payment storage p = payments[receiptId];
        if (p.status != Status.Escrowed) revert NotEscrowed();
        if (p.merchant != msg.sender) revert NotMerchant();
        p.status = Status.Refunded;
        escrowedOf[p.principal] -= p.amount;
        balanceOf[p.principal] += p.amount;
        emit PaymentRefunded(receiptId, p.amount);
    }

    // ─────────────────────────────────────────────────────────── views

    /// @notice Budget left in the current period (accounts for a period that has rolled over).
    function remainingBudget(uint256 id) external view returns (uint256) {
        Mandate storage m = mandates[id];
        if (m.principal == address(0)) return 0;
        (, uint128 spent) = _currentPeriod(m);
        return m.periodBudget - spent;
    }

    // ─────────────────────────────────────────────────────────── internals

    function _check(uint256 id, address caller, Invoice calldata inv, bytes calldata sig, bytes32 digest)
        internal
        view
        returns (Reason)
    {
        if (payments[digest].status != Status.None) return Reason.AlreadySettled;
        Mandate storage m = mandates[id];
        if (m.principal == address(0)) return Reason.UnknownMandate;
        if (caller != m.agent) return Reason.NotMandateAgent;
        if (m.revoked) return Reason.MandateRevoked;
        if (block.timestamp >= m.expiresAt) return Reason.MandateExpired;
        if (!merchantAllowed[id][inv.merchant]) return Reason.MerchantNotAllowed;
        // Signature before amounts: a tampered invoice is reported as tampered, not as "over budget".
        if (!SignatureChecker.isValidSignatureNow(inv.merchant, digest, sig)) return Reason.BadMerchantSignature;
        if (inv.payer != m.principal) return Reason.WrongPayer;
        if (block.timestamp > inv.dueBy) return Reason.InvoiceOverdue;
        if (inv.amount == 0) return Reason.ZeroAmount;
        if (inv.amount > m.perPaymentCap) return Reason.OverPerPaymentCap;
        (, uint128 spent) = _currentPeriod(m);
        if (uint256(spent) + inv.amount > m.periodBudget) return Reason.OverPeriodBudget;
        if (balanceOf[m.principal] < inv.amount) return Reason.InsufficientVaultBalance;
        return Reason.OK;
    }

    /// @dev Periods are aligned to the mandate's creation time, so skipping idle periods
    ///      cannot shift the window.
    function _currentPeriod(Mandate storage m) internal view returns (uint64 start, uint128 spent) {
        if (block.timestamp < uint256(m.periodStart) + m.periodLength) return (m.periodStart, m.spentInPeriod);
        uint256 elapsed = (block.timestamp - m.periodStart) / m.periodLength;
        return (uint64(m.periodStart + elapsed * m.periodLength), 0);
    }

    function _rollPeriod(Mandate storage m) internal {
        (uint64 start, uint128 spent) = _currentPeriod(m);
        if (start != m.periodStart) {
            m.periodStart = start;
            m.spentInPeriod = spent;
        }
    }

    function _release(bytes32 receiptId) internal {
        Payment storage p = payments[receiptId];
        p.status = Status.Released;
        escrowedOf[p.principal] -= p.amount;
        token.safeTransfer(p.merchant, p.amount);
        emit PaymentReleased(receiptId, p.merchant, p.amount, msg.sender);
    }
}
