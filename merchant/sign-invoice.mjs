// Merchant side: produce an EIP-712 signed invoice file the payer's agent can settle.
//
//   MERCHANT_PRIVATE_KEY=0x... node merchant/sign-invoice.mjs \
//     --vault 0xVault --payer 0xPrincipal --amount 120.50 --ref INV-2026-0042 \
//     --due-days 14 --memo "GPU hours, November" --out inbox/INV-2026-0042.json [--rpc https://rpc-test.qday.info]
//
// The key is read from the environment only; it is never written anywhere.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { createPublicClient, http, keccak256, toHex, parseUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { domain, invoiceTypes, isMain, TUSD8_DECIMALS } from "../agent/lib.mjs";

/** Signs an invoice and returns the JSON document stored in an agent inbox. */
export async function signInvoice({ account, chainId, vault, payer, amount, humanRef, dueBy, salt, memo }) {
  const invoice = {
    merchant: account.address,
    payer,
    amount,
    ref: keccak256(toHex(humanRef)),
    dueBy,
    salt,
  };
  const signature = await account.signTypedData({
    domain: domain(chainId, vault),
    types: invoiceTypes,
    primaryType: "Invoice",
    message: invoice,
  });
  return {
    humanRef,
    memo: memo ?? "",
    invoice: { ...invoice, amount: amount.toString(), dueBy: dueBy.toString(), salt: salt.toString() },
    signature,
  };
}

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : def;
}

if (isMain(import.meta.url)) {
  const pk = process.env.MERCHANT_PRIVATE_KEY;
  if (!pk) {
    console.error("Set MERCHANT_PRIVATE_KEY in the environment.");
    process.exit(2);
  }
  const rpc = arg("rpc", "https://rpc-test.qday.info");
  const chainId = await createPublicClient({ transport: http(rpc) }).getChainId();
  const doc = await signInvoice({
    account: privateKeyToAccount(pk),
    chainId,
    vault: arg("vault"),
    payer: arg("payer"),
    amount: parseUnits(arg("amount"), TUSD8_DECIMALS),
    humanRef: arg("ref"),
    dueBy: BigInt(Math.floor(Date.now() / 1000) + Number(arg("due-days", "14")) * 86400),
    salt: BigInt(Date.now()),
    memo: arg("memo", ""),
  });
  const out = arg("out", `inbox/${doc.humanRef}.json`);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify(doc, null, 2));
  console.log(`signed ${doc.humanRef} -> ${out}`);
}
