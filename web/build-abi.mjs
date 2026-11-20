// Copies the compiled ABIs the web UI needs into web/abi.json (run after `forge build`).
import { writeFileSync } from "node:fs";
import { artifact } from "../agent/lib.mjs";
const out = { MandateVault: artifact("MandateVault").abi, ERC20: artifact("MockUSD8").abi };
writeFileSync(new URL("./abi.json", import.meta.url), JSON.stringify(out));
console.log("web/abi.json written");
