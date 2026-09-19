/* global console, process */
import { readFileSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

// Follow only static imports: optional dynamic features have their own budgets.
// A Set counts shared dependencies and CSS once, including cyclic chunk graphs.
export function collectAssets(manifest, roots) {
  const visited = new Set();
  const files = new Set();
  function visit(key) {
    if (visited.has(key)) return;
    const entry = manifest[key];
    if (!entry || typeof entry.file !== "string") throw new Error(`Missing manifest entry: ${key}`);
    visited.add(key);
    if (/\.(js|css)$/.test(entry.file)) files.add(entry.file);
    for (const css of entry.css || []) files.add(css);
    for (const dependency of entry.imports || []) visit(dependency);
  }
  roots.forEach(visit);
  return [...files].sort();
}

export function measureAssets(files, readAsset) {
  return files.reduce((total, file) => {
    const bytes = readAsset(file);
    return { raw: total.raw + bytes.length, gzip: total.gzip + gzipSync(bytes).length };
  }, { raw: 0, gzip: 0 });
}

export function checkBudgets(manifest, budgets, readAsset) {
  const rows = [];
  const failures = [];
  function check(name, files, limit) {
    if (!Number.isInteger(limit.raw) || limit.raw <= 0 ||
        !Number.isInteger(limit.gzip) || limit.gzip <= 0) {
      throw new Error(`Invalid asset budget: ${name}`);
    }
    const measured = measureAssets(files, readAsset);
    rows.push({ name, files: files.length, ...measured, limit });
    for (const metric of ["raw", "gzip"]) {
      if (measured[metric] > limit[metric]) {
        failures.push(`${name}: ${metric} ${measured[metric]} > ${limit[metric]} bytes`);
      }
    }
  }
  if (budgets.schema !== 1 || !budgets.routes?.length) throw new Error("Missing route budgets");
  for (const route of budgets.routes) {
    if (!route.entries?.length) throw new Error(`Missing route entries: ${route.name}`);
    check(route.name, collectAssets(manifest, route.entries), route);
  }
  // Include every emitted JS/CSS chunk, even optional dynamic imports. Splitting
  // a large feature into smaller chunks must not bypass the aggregate ceiling.
  const all = collectAssets(manifest, Object.keys(manifest));
  check("all emitted JS/CSS", all, budgets.total);
  return { rows, failures };
}

export function readBuiltAsset(dist, file) {
  const path = resolve(dist, file);
  const inside = relative(dist, path);
  if (isAbsolute(file) || !inside || inside.startsWith("..") || isAbsolute(inside)) {
    throw new Error(`Asset is outside the build directory: ${file}`);
  }
  return readFileSync(path);
}

function main() {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const dist = resolve(root, "dist");
  const manifest = JSON.parse(readFileSync(resolve(dist, ".vite/manifest.json"), "utf8"));
  const budgets = JSON.parse(readFileSync(resolve(root, "asset-budgets.json"), "utf8"));
  const result = checkBudgets(manifest, budgets, (file) => readBuiltAsset(dist, file));
  for (const row of result.rows) {
    console.log(`${row.name}: ${row.raw}/${row.limit.raw} raw, ${row.gzip}/${row.limit.gzip} gzip bytes (${row.files} JS/CSS assets)`);
  }
  if (result.failures.length) throw new Error(`Asset budgets exceeded:\n${result.failures.join("\n")}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
