// Purchasing agent: settles merchant-signed invoices from an inbox under an on-chain mandate.
//
// Design rules
//  1. The chain is the policy. The agent asks MandateVault.check() before it spends gas,
//     and pay() re-checks everything — a buggy or compromised agent cannot exceed limits.
//  2. Idempotent. The receipt id is the invoice's EIP-712 digest. Before every attempt
//     (including retries after a timeout) the agent reads the receipt status; a receipt
//     that already exists is never paid again.
//  3. Free text is data, never instructions. `memo` is logged verbatim and ignored for
//     every decision; only merchant-signed fields count.
//  4. Human in the loop above a threshold. Invoices above `autoApproveLimit` are staged
//     until the principal lists their receipt id in the approvals file.
//  5. Everything is written to an append-only JSONL audit log with tx hashes.
//
//   AGENT_PRIVATE_KEY=0x... node agent/agent.mjs --vault 0x.. --mandate 1 --inbox inbox \
//     [--rpc https://rpc-test.qday.info] [--auto-approve 250] [--approvals approvals.json] [--audit audit.jsonl]
import { readdirSync, readFileSync, appendFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { createPublicClient, createWalletClient, http, parseUnits, BaseError, ContractFunctionRevertedError } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { artifact, EXPLAIN, fmtUsd, isMain, REASONS, sleep, STATUS, toInvoiceStruct, TUSD8_DECIMALS } from "./lib.mjs";

const { abi } = artifact("MandateVault");

/**
 * Process one invoice document. Returns an audit record; never throws for policy outcomes.
 * @param {object} ctx { publicClient, walletClient, vault, mandateId, autoApproveLimit, approvals:Set, retries, confirmTimeoutMs }
 */
export async function settle(ctx, doc, source = "") {
  const { publicClient, walletClient, vault, mandateId } = ctx;
  const inv = toInvoiceStruct(doc.invoice);
  const base = {
    at: new Date().toISOString(),
    source,
    humanRef: doc.humanRef,
    merchant: inv.merchant,
    amount: inv.amount.toString(),
    amountText: fmtUsd(inv.amount),
    memo: doc.memo ?? "", // recorded, never interpreted
  };

  let receiptId;
  try {
    receiptId = await publicClient.readContract({ address: vault, abi, functionName: "invoiceDigest", args: [inv] });
  } catch (e) {
    return { ...base, decision: "ERROR", detail: `malformed invoice: ${short(e)}` };
  }
  base.receiptId = receiptId;

  const status = await receiptStatus(publicClient, vault, receiptId);
  if (status !== "None") {
    return { ...base, decision: "SKIPPED", reason: "AlreadySettled", detail: `receipt already ${status} — not paying twice` };
  }

  const reasonIdx = await publicClient.readContract({
    address: vault,
    abi,
    functionName: "check",
    args: [mandateId, walletClient.account.address, inv, doc.signature],
  });
  const reason = REASONS[Number(reasonIdx)];
  if (reason !== "OK") return { ...base, decision: "REFUSED", reason, detail: EXPLAIN[reason] };

  if (ctx.autoApproveLimit !== undefined && inv.amount > ctx.autoApproveLimit && !ctx.approvals.has(receiptId.toLowerCase())) {
    return {
      ...base,
      decision: "NEEDS_APPROVAL",
      detail: `above auto-approve limit ${fmtUsd(ctx.autoApproveLimit)} — add the receipt id to the approvals file`,
    };
  }

  // Send with bounded retries. Each retry first asks the chain whether a previous attempt landed.
  const retries = ctx.retries ?? 3;
  for (let attempt = 1; attempt <= retries; attempt++) {
    if (attempt > 1) {
      const s = await receiptStatus(publicClient, vault, receiptId);
      if (s !== "None") return { ...base, decision: "PAID", detail: `confirmed on re-check after retry (${s})`, attempt };
    }
    try {
      const { request } = await publicClient.simulateContract({
        account: walletClient.account,
        address: vault,
        abi,
        functionName: "pay",
        args: [mandateId, inv, doc.signature],
      });
      const hash = await walletClient.writeContract(request);
      const rcpt = await publicClient.waitForTransactionReceipt({ hash, timeout: ctx.confirmTimeoutMs ?? 60_000 });
      if (rcpt.status !== "success") throw new Error(`tx ${hash} reverted`);
      const after = await receiptStatus(publicClient, vault, receiptId);
      return { ...base, decision: "PAID", txHash: hash, block: rcpt.blockNumber.toString(), status: after, attempt };
    } catch (e) {
      const policy = policyRevert(e);
      if (policy) return { ...base, decision: "REFUSED", reason: policy, detail: EXPLAIN[policy], attempt };
      if (attempt === retries) return { ...base, decision: "ERROR", detail: short(e), attempt };
      await sleep(500 * 2 ** attempt);
    }
  }
}

export async function receiptStatus(publicClient, vault, receiptId) {
  const p = await publicClient.readContract({ address: vault, abi, functionName: "payments", args: [receiptId] });
  return STATUS[Number(p[5])];
}

function policyRevert(e) {
  if (!(e instanceof BaseError)) return null;
  const r = e.walk((x) => x instanceof ContractFunctionRevertedError);
  if (r?.data?.errorName === "PaymentRejected") return REASONS[Number(r.data.args[0])];
  return null;
}

function short(e) {
  return (e?.shortMessage ?? e?.message ?? String(e)).split("\n")[0];
}

/** Reads every *.json in the inbox (sorted) and settles them in order. */
export async function runInbox(ctx, inboxDir, auditFile) {
  const files = readdirSync(inboxDir).filter((f) => f.endsWith(".json")).sort();
  const out = [];
  for (const f of files) {
    let doc;
    try {
      doc = JSON.parse(readFileSync(join(inboxDir, f), "utf8"));
    } catch (e) {
      out.push({ at: new Date().toISOString(), source: f, decision: "ERROR", detail: `unreadable: ${short(e)}` });
      continue;
    }
    const rec = await settle(ctx, doc, f);
    out.push(rec);
    if (auditFile) appendFileSync(auditFile, JSON.stringify(rec) + "\n");
  }
  return out;
}

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : def;
}

if (isMain(import.meta.url)) {
  const pk = process.env.AGENT_PRIVATE_KEY;
  if (!pk) {
    console.error("Set AGENT_PRIVATE_KEY in the environment (a dedicated, low-value agent key).");
    process.exit(2);
  }
  const rpc = arg("rpc", "https://rpc-test.qday.info");
  const transport = http(rpc, { retryCount: 3 });
  const publicClient = createPublicClient({ transport });
  const chain = { id: await publicClient.getChainId(), name: "target", nativeCurrency: { name: "gas", symbol: "gas", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } };
  const walletClient = createWalletClient({ account: privateKeyToAccount(pk), chain, transport });
  const approvalsFile = arg("approvals", "approvals.json");
  const approvals = new Set(existsSync(approvalsFile) ? JSON.parse(readFileSync(approvalsFile, "utf8")).map((x) => x.toLowerCase()) : []);
  const auto = arg("auto-approve");
  const ctx = {
    publicClient,
    walletClient,
    vault: arg("vault"),
    mandateId: BigInt(arg("mandate", "1")),
    autoApproveLimit: auto === undefined ? undefined : parseUnits(auto, TUSD8_DECIMALS),
    approvals,
  };
  const recs = await runInbox(ctx, arg("inbox", "inbox"), arg("audit", "audit.jsonl"));
  for (const r of recs) console.log(`${r.decision.padEnd(15)} ${String(r.humanRef ?? r.source).padEnd(16)} ${r.amountText ?? ""}  ${r.reason ?? ""} ${r.txHash ?? r.detail ?? ""}`);
}
