// Pure view-model helpers for the dashboard (no I/O, no imports — unit-tested in node).

export const REASONS = [
  "OK", "AlreadySettled", "UnknownMandate", "NotMandateAgent", "MandateRevoked", "MandateExpired",
  "MerchantNotAllowed", "WrongPayer", "InvoiceOverdue", "ZeroAmount", "OverPerPaymentCap",
  "OverPeriodBudget", "InsufficientVaultBalance", "BadMerchantSignature",
];

export const EXPLAIN = {
  OK: "Within mandate — the agent can pay this.",
  AlreadySettled: "This invoice already has a receipt; paying again would be a duplicate.",
  UnknownMandate: "That mandate id does not exist.",
  NotMandateAgent: "That address is not the agent this mandate was granted to.",
  MandateRevoked: "The mandate was revoked.",
  MandateExpired: "The mandate has expired.",
  MerchantNotAllowed: "The merchant is not on this mandate's allowlist.",
  WrongPayer: "The invoice is addressed to a different payer.",
  InvoiceOverdue: "The invoice is past its due date.",
  ZeroAmount: "The invoice amount is zero.",
  OverPerPaymentCap: "The amount is above the per-payment cap.",
  OverPeriodBudget: "Paying this would exceed the budget for the current period.",
  InsufficientVaultBalance: "The vault balance is too low.",
  BadMerchantSignature: "The signature does not match — the invoice was altered or not signed by the merchant.",
};

export function fmt(base, decimals = 6) {
  const n = BigInt(base);
  const d = 10n ** BigInt(decimals);
  const frac = (n % d).toString().padStart(decimals, "0").slice(0, 2);
  return `${(n / d).toLocaleString("en-US")}.${frac}`;
}

/** Decimal string -> base units. Rejects anything that is not a plain positive number. */
export function parseAmount(text, decimals = 6) {
  const s = String(text).trim();
  if (!/^\d+(\.\d+)?$/.test(s)) throw new Error(`"${text}" is not an amount`);
  const [w, f = ""] = s.split(".");
  if (f.length > decimals) throw new Error(`at most ${decimals} decimal places`);
  return BigInt(w) * 10n ** BigInt(decimals) + BigInt(f.padEnd(decimals, "0") || "0");
}

/**
 * Folds decoded vault events (sorted by block/log index) into mandates and receipts.
 * Each event: { eventName, args, transactionHash, blockNumber }.
 */
export function fold(events) {
  const mandates = new Map();
  const receipts = new Map();
  for (const e of events) {
    const a = e.args;
    switch (e.eventName) {
      case "MandateCreated":
        mandates.set(a.mandateId.toString(), {
          id: a.mandateId, principal: a.principal, agent: a.agent, perPaymentCap: a.perPaymentCap,
          periodBudget: a.periodBudget, periodLength: a.periodLength, expiresAt: a.expiresAt,
          coolingOff: a.coolingOff, merchants: new Set(), revoked: false, tx: e.transactionHash,
        });
        break;
      case "MerchantSet": {
        const m = mandates.get(a.mandateId.toString());
        if (m) a.allowed ? m.merchants.add(a.merchant) : m.merchants.delete(a.merchant);
        break;
      }
      case "MandateRevoked": {
        const m = mandates.get(a.mandateId.toString());
        if (m) m.revoked = true;
        break;
      }
      case "PaymentEscrowed":
        receipts.set(a.receiptId, {
          id: a.receiptId, mandateId: a.mandateId, merchant: a.merchant, agent: a.agent, amount: a.amount,
          ref: a.ref, releaseAt: a.releaseAt, status: "Escrowed", txs: [{ kind: "paid", hash: e.transactionHash }],
        });
        break;
      case "PaymentReleased":
      case "PaymentClawedBack":
      case "PaymentRefunded": {
        const r = receipts.get(a.receiptId);
        if (!r) break;
        r.status = { PaymentReleased: "Released", PaymentClawedBack: "ClawedBack", PaymentRefunded: "Refunded" }[e.eventName];
        r.txs.push({ kind: r.status, hash: e.transactionHash });
        if (a.note) r.note = a.note;
        break;
      }
    }
  }
  return { mandates, receipts };
}

/** What the viewer may do with a receipt right now. */
export function actionsFor(receipt, mandate, me, nowSec) {
  const out = [];
  if (receipt.status !== "Escrowed") return out;
  const now = BigInt(nowSec);
  const isPrincipal = !!me && !!mandate && mandate.principal.toLowerCase() === me.toLowerCase();
  if (now < receipt.releaseAt && isPrincipal) out.push("clawback");
  if (now >= receipt.releaseAt) out.push("release");
  if (me && receipt.merchant.toLowerCase() === me.toLowerCase()) out.push("refund");
  return out;
}

export function countdown(releaseAt, nowSec) {
  const s = Number(BigInt(releaseAt) - BigInt(nowSec));
  if (s <= 0) return "releasable now";
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
  return h ? `releases in ${h}h ${m}m` : `releases in ${m}m ${s % 60}s`;
}
