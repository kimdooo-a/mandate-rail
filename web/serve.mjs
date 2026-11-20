// Minimal static server for the dashboard:  node web/serve.mjs [port]
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL(".", import.meta.url));
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".json": "application/json", ".css": "text/css", ".svg": "image/svg+xml" };
const port = Number(process.argv[2] ?? 5173);

createServer(async (req, res) => {
  let file;
  try {
    const rel = decodeURIComponent(new URL(req.url, "http://x").pathname).replace(/^[/\\]+/, "");
    file = normalize(join(ROOT, rel || "index.html"));
  } catch {
    return res.writeHead(400).end();
  }
  if (!file.startsWith(normalize(ROOT))) return res.writeHead(403).end(); // no path traversal
  try {
    const body = await readFile(file);
    res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream" }).end(body);
  } catch {
    res.writeHead(404).end("not found");
  }
}).listen(port, "127.0.0.1", () => console.log(`MandateRail dashboard: http://127.0.0.1:${port}/`));
