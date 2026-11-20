// MandateRail dashboard. Reads everything from the chain (events + views); writes through the
// connected wallet. No backend, no keys in the page.
import {
  createPublicClient, createWalletClient, custom, http, parseEventLogs, BaseError, ContractFunctionRevertedError,
} from "https://esm.sh/viem@2.58.2";
import { REASONS, EXPLAIN, fmt, parseAmount, fold, actionsFor, countdown } from "./model.mjs";

const $ = (id) => document.getElementById(id);
const AEVUM = {
  id: 44005,
  name: "QDay Aevum Testnet",
  nativeCurrency: { name: "tQDAY", symbol: "tQDAY", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc-test.qday.info"] } },
  blockExplorers: { default: { name: "QDay Explorer", url: "https://explorer-test.qday.info" } },
};

const abi = await (await fetch("abi.json")).json();
const S = { pub: null, wallet: null, me: null, vault: null, token: null, chainId: null, mandates: new Map(), receipts: new Map() };

// Query string pre-fills (?vault=0x..&rpc=..&from=123) so a demo link opens ready to go.
const q = new URLSearchParams(location.search);
if (q.get("vault")) $("vault").value = q.get("vault");
if (q.get("rpc")) $("rpc").value = q.get("rpc");
if (q.get("from")) $("fromBlock").value = q.get("from");

function status(msg, kind = "") {
  const el = $("status");
  el.textContent = msg;
  el.className = kind;
}

function explain(e) {
  if (e instanceof BaseError) {
    const r = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (r?.data?.errorName === "PaymentRejected") {
      const reason = REASONS[Number(r.data.args[0])];
      return `${reason}: ${EXPLAIN[reason]}`;
    }
    if (r?.data?.errorName) return `Refused by the vault: ${r.data.errorName}`;
    return e.shortMessage;
  }
  return e?.message ?? String(e);
}

async function guard(label, fn) {
  try {
    status(`${label}…`);
    await fn();
  } catch (e) {
    status(`${label} failed — ${explain(e)}`, "err");
    console.error(e);
  }
}

function explorerTx(hash) {
  if (S.chainId !== 44005) return `<span class="mono">${hash.slice(0, 12)}…</span>`;
  return `<a class="mono" target="_blank" rel="noopener" href="https://explorer-test.qday.info/tx/${hash}">${hash.slice(0, 12)}…</a>`;
}

const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;

// ───────────────────────────────────────── wallet

$("connect").onclick = () =>
  guard("Connecting wallet", async () => {
    if (!window.ethereum) throw new Error("No browser wallet found. Install MetaMask to sign transactions (reading works without it).");
    const [addr] = await window.ethereum.request({ method: "eth_requestAccounts" });
    S.me = addr;
    const want = S.chainId ?? 44005;
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: `0x${want.toString(16)}` }] });
    } catch (e) {
      if (e.code === 4902 && want === 44005) {
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [{ chainId: "0xabe5", chainName: AEVUM.name, nativeCurrency: AEVUM.nativeCurrency, rpcUrls: AEVUM.rpcUrls.default.http, blockExplorerUrls: [AEVUM.blockExplorers.default.url] }],
        });
      } else throw e;
    }
    S.wallet = createWalletClient({ account: addr, chain: { ...AEVUM, id: want }, transport: custom(window.ethereum) });
    $("me").textContent = short(addr);
    $("connect").textContent = short(addr);
    if (S.vault) await refresh();
    status("Wallet connected.", "ok");
  });

async function write(label, address, theAbi, functionName, args) {
  if (!S.wallet) throw new Error("Connect a wallet first.");
  const { request } = await S.pub.simulateContract({ account: S.me, address, abi: theAbi, functionName, args });
  status(`${label}: confirm in your wallet…`);
  const hash = await S.wallet.writeContract(request);
  status(`${label}: waiting for confirmation (${hash.slice(0, 12)}…)`);
  const r = await S.pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  if (r.status !== "success") throw new Error(`transaction ${hash} reverted`);
  status(`${label}: confirmed in block ${r.blockNumber}.`, "ok");
  return hash;
}

// ───────────────────────────────────────── load

$("load").onclick = () =>
  guard("Loading vault", async () => {
    const vault = $("vault").value.trim();
    if (!/^0x[0-9a-fA-F]{40}$/.test(vault)) throw new Error("Enter the MandateVault address (0x + 40 hex).");
    S.pub = createPublicClient({ transport: http($("rpc").value.trim(), { retryCount: 3 }) });
    S.chainId = await S.pub.getChainId();
    S.vault = vault;
    S.token = await S.pub.readContract({ address: vault, abi: abi.MandateVault, functionName: "token" });
    $("chainId").textContent = S.chainId === 44005 ? "44005 (Aevum testnet)" : String(S.chainId);
    $("token").textContent = short(S.token);
    await refresh();
    status("Loaded.", "ok");
  });

async function scanLogs() {
  const latest = await S.pub.getBlockNumber();
  let from = BigInt($("fromBlock").value || "0");
  const STEP = 1_000n; // Aevum RPC: "block range too large, max range: 1000"
  const logs = [];
  while (from <= latest) {
    const to = from + STEP - 1n > latest ? latest : from + STEP - 1n;
    logs.push(...(await S.pub.getLogs({ address: S.vault, fromBlock: from, toBlock: to })));
    from = to + 1n;
  }
  return parseEventLogs({ abi: abi.MandateVault, logs });
}

async function refresh() {
  const events = await scanLogs();
  const { mandates, receipts } = fold(events);
  S.mandates = mandates;
  S.receipts = receipts;
  const now = (await S.pub.getBlock()).timestamp;

  if (S.me) {
    const [free, esc, wal] = await Promise.all([
      S.pub.readContract({ address: S.vault, abi: abi.MandateVault, functionName: "balanceOf", args: [S.me] }),
      S.pub.readContract({ address: S.vault, abi: abi.MandateVault, functionName: "escrowedOf", args: [S.me] }),
      S.pub.readContract({ address: S.token, abi: abi.ERC20, functionName: "balanceOf", args: [S.me] }),
    ]);
    $("free").textContent = fmt(free);
    $("escrow").textContent = fmt(esc);
    $("wallet").textContent = fmt(wal);
  }

  // mandates (mine first; everyone's are public on-chain anyway)
  const mine = [...mandates.values()].filter((m) => !S.me || m.principal.toLowerCase() === S.me.toLowerCase());
  const box = $("mandates");
  box.innerHTML = mine.length ? "" : `<p class="hint">No mandates${S.me ? " granted by this wallet" : ""} yet.</p>`;
  for (const m of mine) {
    const remaining = await S.pub.readContract({ address: S.vault, abi: abi.MandateVault, functionName: "remainingBudget", args: [m.id] });
    const used = Number(m.periodBudget - remaining) / Number(m.periodBudget);
    const expired = now >= m.expiresAt;
    const el = document.createElement("div");
    el.className = "item";
    el.innerHTML = `
      <div class="grow">
        <strong>#${m.id}</strong> agent <span class="mono">${m.agent}</span>
        ${m.revoked ? '<span class="pill revoked">revoked</span>' : expired ? '<span class="pill revoked">expired</span>' : ""}
        <div class="hint">cap ${fmt(m.perPaymentCap)} / payment · ${fmt(remaining)} of ${fmt(m.periodBudget)} left this period ·
        cooling-off ${Number(m.coolingOff) / 60} min · expires ${new Date(Number(m.expiresAt) * 1000).toLocaleString()}</div>
        <div class="hint">merchants: ${[...m.merchants].map((x) => `<span class="mono">${short(x)}</span>`).join(", ") || "none"}</div>
        <div class="bar"><i style="width:${Math.min(100, Math.round(used * 100))}%"></i></div>
      </div>`;
    if (!m.revoked && S.me && m.principal.toLowerCase() === S.me.toLowerCase()) {
      const b = document.createElement("button");
      b.className = "danger";
      b.textContent = "Revoke";
      b.onclick = () => guard(`Revoking mandate #${m.id}`, async () => {
        if (!confirm(`Revoke mandate #${m.id}? The agent will be unable to pay immediately.`)) return;
        await write("Revoke", S.vault, abi.MandateVault, "revokeMandate", [m.id]);
        await refresh();
      });
      el.appendChild(b);
    }
    box.appendChild(el);
  }

  // receipts
  const rbox = $("receipts");
  const list = [...receipts.values()].reverse();
  rbox.innerHTML = list.length ? "" : '<p class="hint">No payments yet.</p>';
  for (const r of list) {
    const m = mandates.get(r.mandateId.toString());
    const el = document.createElement("div");
    el.className = "item";
    el.innerHTML = `
      <div class="grow">
        <strong>${fmt(r.amount)} tUSD8</strong> → <span class="mono">${short(r.merchant)}</span>
        <span class="pill ${r.status}">${r.status}</span>
        <div class="hint">mandate #${r.mandateId} · ${r.status === "Escrowed" ? countdown(r.releaseAt, now) : r.note ? `note: “${escapeHtml(r.note)}”` : ""}</div>
        <div class="hint">receipt <span class="mono">${r.id}</span></div>
        <div class="hint">${r.txs.map((t) => `${t.kind} ${explorerTx(t.hash)}`).join(" · ")}</div>
      </div>`;
    for (const act of actionsFor(r, m, S.me, now)) {
      const b = document.createElement("button");
      b.className = act === "clawback" ? "danger" : "ghost";
      b.textContent = { clawback: "Claw back", release: "Release", refund: "Refund" }[act];
      b.onclick = () => guard(b.textContent, async () => {
        if (act === "clawback") {
          const note = prompt("Reason for the clawback (stored on-chain):", "") ?? "";
          await write("Clawback", S.vault, abi.MandateVault, "clawback", [r.id, note]);
        } else if (act === "release") await write("Release", S.vault, abi.MandateVault, "release", [r.id]);
        else await write("Refund", S.vault, abi.MandateVault, "merchantRefund", [r.id]);
        await refresh();
      });
      el.appendChild(b);
    }
    rbox.appendChild(el);
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

// ───────────────────────────────────────── principal actions

$("deposit").onclick = () =>
  guard("Depositing", async () => {
    const amt = parseAmount($("depAmt").value);
    const allowance = await S.pub.readContract({ address: S.token, abi: abi.ERC20, functionName: "allowance", args: [S.me, S.vault] });
    if (allowance < amt) await write("Approve", S.token, abi.ERC20, "approve", [S.vault, amt]);
    await write("Deposit", S.vault, abi.MandateVault, "deposit", [amt]);
    await refresh();
  });

$("withdraw").onclick = () =>
  guard("Withdrawing", async () => {
    await write("Withdraw", S.vault, abi.MandateVault, "withdraw", [parseAmount($("depAmt").value)]);
    await refresh();
  });

$("grant").onclick = () =>
  guard("Granting mandate", async () => {
    const addr = (s) => {
      const v = s.trim();
      if (!/^0x[0-9a-fA-F]{40}$/.test(v)) throw new Error(`"${v}" is not an address`);
      return v;
    };
    const merchants = $("mMerchants").value.split(",").map((s) => s.trim()).filter(Boolean).map(addr);
    const now = BigInt(Math.floor(Date.now() / 1000));
    await write("Grant", S.vault, abi.MandateVault, "createMandate", [
      addr($("mAgent").value),
      parseAmount($("mCap").value),
      parseAmount($("mBudget").value),
      BigInt(Math.round(Number($("mPeriod").value) * 3600)),
      now + BigInt(Math.round(Number($("mDays").value) * 86400)),
      BigInt(Math.round(Number($("mCool").value) * 60)),
      merchants,
    ]);
    await refresh();
  });

// ───────────────────────────────────────── pre-flight

$("preflight").onclick = () =>
  guard("Checking invoice", async () => {
    if (!S.pub) throw new Error("Load a vault first.");
    let doc;
    try {
      doc = JSON.parse($("pfJson").value);
    } catch {
      throw new Error("That is not valid JSON.");
    }
    const j = doc.invoice;
    const inv = { merchant: j.merchant, payer: j.payer, amount: BigInt(j.amount), ref: j.ref, dueBy: BigInt(j.dueBy), salt: BigInt(j.salt) };
    const id = BigInt($("pfMandate").value);
    const agent = $("pfAgent").value.trim() || S.mandates.get(id.toString())?.agent;
    if (!agent) throw new Error("Enter the agent address (or load a vault that has this mandate).");
    const [idx, digest] = await Promise.all([
      S.pub.readContract({ address: S.vault, abi: abi.MandateVault, functionName: "check", args: [id, agent, inv, doc.signature] }),
      S.pub.readContract({ address: S.vault, abi: abi.MandateVault, functionName: "invoiceDigest", args: [inv] }),
    ]);
    const reason = REASONS[Number(idx)];
    $("pfOut").innerHTML = `<p><span class="pill ${reason === "OK" ? "Released" : "ClawedBack"}">${reason}</span> ${EXPLAIN[reason]}</p>
      <p class="hint">${escapeHtml(doc.humanRef ?? "")} · ${fmt(inv.amount)} tUSD8 · receipt id <span class="mono">${digest}</span></p>
      ${doc.memo ? `<p class="hint">memo (shown, never acted on): “${escapeHtml(doc.memo)}”</p>` : ""}`;
    status("Pre-flight done — nothing was sent.", "ok");
  });

// Keep countdowns honest.
setInterval(() => S.vault && S.pub && refresh().catch(() => {}), 30_000);
