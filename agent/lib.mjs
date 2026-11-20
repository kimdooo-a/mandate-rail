// Shared helpers for the agent, merchant tool, demo and web UI build.
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineChain } from "viem";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

export const aevumTestnet = defineChain({
  id: 44005,
  name: "QDay Aevum Testnet",
  nativeCurrency: { name: "tQDAY", symbol: "tQDAY", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://rpc-test.qday.info"], webSocket: ["wss://rpc-test.qday.info"] },
  },
  blockExplorers: { default: { name: "QDay Explorer", url: "https://explorer-test.qday.info" } },
  testnet: true,
});

export const TUSD8_AEVUM = "0x456569838f1d43009A91ebA4263147Afd7233483";
export const TUSD8_DECIMALS = 6;

/** Reads a compiled artifact from Foundry's out/ directory. */
export function artifact(name, file = `${name}.sol`) {
  const j = JSON.parse(readFileSync(join(ROOT, "out", file, `${name}.json`), "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}

/** Order must match `enum Reason` in MandateVault.sol. */
export const REASONS = [
  "OK",
  "AlreadySettled",
  "UnknownMandate",
  "NotMandateAgent",
  "MandateRevoked",
  "MandateExpired",
  "MerchantNotAllowed",
  "WrongPayer",
  "InvoiceOverdue",
  "ZeroAmount",
  "OverPerPaymentCap",
  "OverPeriodBudget",
  "InsufficientVaultBalance",
  "BadMerchantSignature",
];

/** Plain-language explanations shown to the principal. */
export const EXPLAIN = {
  OK: "Within mandate — payable.",
  AlreadySettled: "This exact invoice already has a receipt; paying again would be a duplicate.",
  UnknownMandate: "The mandate id does not exist.",
  NotMandateAgent: "This agent key is not the one the mandate was granted to.",
  MandateRevoked: "The principal revoked this mandate.",
  MandateExpired: "The mandate has expired.",
  MerchantNotAllowed: "Merchant is not on the mandate's allowlist.",
  WrongPayer: "Invoice is addressed to a different payer.",
  InvoiceOverdue: "Invoice is past its due date.",
  ZeroAmount: "Invoice amount is zero.",
  OverPerPaymentCap: "Amount is above the per-payment cap.",
  OverPeriodBudget: "Paying this would exceed the budget for the current period.",
  InsufficientVaultBalance: "Vault balance is too low.",
  BadMerchantSignature: "Signature does not match the invoice — it was altered or not signed by the merchant.",
};

export const STATUS = ["None", "Escrowed", "Released", "ClawedBack", "Refunded"];

export const invoiceTypes = {
  Invoice: [
    { name: "merchant", type: "address" },
    { name: "payer", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "ref", type: "bytes32" },
    { name: "dueBy", type: "uint64" },
    { name: "salt", type: "uint256" },
  ],
};

export function domain(chainId, vault) {
  return { name: "MandateVault", version: "1", chainId, verifyingContract: vault };
}

/** JSON on disk keeps bigints as strings; turn them back into the on-chain struct. */
export function toInvoiceStruct(j) {
  return {
    merchant: j.merchant,
    payer: j.payer,
    amount: BigInt(j.amount),
    ref: j.ref,
    dueBy: BigInt(j.dueBy),
    salt: BigInt(j.salt),
  };
}

export function fmtUsd(base) {
  const n = BigInt(base);
  const whole = n / 1_000_000n;
  const frac = (n % 1_000_000n).toString().padStart(6, "0").slice(0, 2);
  return `${whole.toLocaleString("en-US")}.${frac} tUSD8`;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** True when the module is the script node was asked to run (not an import). */
export function isMain(metaUrl) {
  return !!process.argv[1] && fileURLToPath(metaUrl) === resolve(process.argv[1]);
}
