// node --test web/model.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { fold, actionsFor, parseAmount, fmt, countdown, REASONS } from "./model.mjs";
import { REASONS as AGENT_REASONS } from "../agent/lib.mjs";

const P = "0x1111111111111111111111111111111111111111";
const A = "0x2222222222222222222222222222222222222222";
const M = "0x3333333333333333333333333333333333333333";

const ev = (eventName, args, tx = "0xaa") => ({ eventName, args, transactionHash: tx });

test("reason table matches the agent's copy (and the enum order)", () => {
  assert.deepEqual(REASONS, AGENT_REASONS);
});

test("fold builds mandates and receipt lifecycles", () => {
  const { mandates, receipts } = fold([
    ev("MandateCreated", { mandateId: 1n, principal: P, agent: A, perPaymentCap: 5n, periodBudget: 10n, periodLength: 60n, expiresAt: 999n, coolingOff: 10n }),
    ev("MerchantSet", { mandateId: 1n, merchant: M, allowed: true }),
    ev("PaymentEscrowed", { receiptId: "0x01", mandateId: 1n, merchant: M, agent: A, amount: 5n, ref: "0x", releaseAt: 100n }, "0xp1"),
    ev("PaymentEscrowed", { receiptId: "0x02", mandateId: 1n, merchant: M, agent: A, amount: 3n, ref: "0x", releaseAt: 100n }, "0xp2"),
    ev("PaymentClawedBack", { receiptId: "0x02", amount: 3n, note: "dup" }, "0xc2"),
    ev("MerchantSet", { mandateId: 1n, merchant: M, allowed: false }),
    ev("MandateRevoked", { mandateId: 1n }),
  ]);
  const m = mandates.get("1");
  assert.equal(m.revoked, true);
  assert.equal(m.merchants.size, 0);
  assert.equal(receipts.get("0x01").status, "Escrowed");
  assert.equal(receipts.get("0x02").status, "ClawedBack");
  assert.equal(receipts.get("0x02").note, "dup");
  assert.deepEqual(receipts.get("0x02").txs.map((t) => t.kind), ["paid", "ClawedBack"]);
});

test("actions depend on role and time", () => {
  const m = { principal: P };
  const r = { status: "Escrowed", releaseAt: 100n, merchant: M };
  assert.deepEqual(actionsFor(r, m, P, 50), ["clawback"]);
  assert.deepEqual(actionsFor(r, m, P, 100), ["release"]);
  assert.deepEqual(actionsFor(r, m, M, 50), ["refund"]);
  assert.deepEqual(actionsFor(r, m, null, 150), ["release"]);
  assert.deepEqual(actionsFor({ ...r, status: "Released" }, m, P, 150), []);
});

test("amount parsing is strict", () => {
  assert.equal(parseAmount("12.5"), 12_500_000n);
  assert.equal(parseAmount("0.000001"), 1n);
  assert.throws(() => parseAmount("1e3"));
  assert.throws(() => parseAmount("-1"));
  assert.throws(() => parseAmount("0.0000001"));
  assert.equal(fmt(1_234_567_890n), "1,234.56");
  assert.equal(countdown(100n, 100), "releasable now");
  assert.equal(countdown(3700n, 0), "releases in 1h 1m");
});
