/* global Buffer */
import assert from "node:assert/strict";
import test from "node:test";
import { gzipSync } from "node:zlib";
import { checkBudgets, collectAssets, measureAssets, readBuiltAsset } from "./check-asset-budgets.mjs";

const manifest = {
  shell: { file: "shell.js", imports: ["shared"], css: ["app.css"], dynamicImports: ["board"] },
  inbox: { file: "inbox.js", imports: ["shared", "shell"], css: ["app.css"] },
  shared: { file: "shared.js", imports: ["shell"] },
  board: { file: "board.js" }
};
const read = (file) => Buffer.from(file.repeat(100));
const limit = { raw: 100000, gzip: 100000 };
const budget = () => ({ schema: 1, routes: [{ name: "inbox", entries: ["shell", "inbox"], ...limit }], total: limit });

test("route closure counts cyclic shared imports and CSS once, excluding optional dynamic imports", () => {
  assert.deepEqual(collectAssets(manifest, ["shell", "inbox"]), ["app.css", "inbox.js", "shared.js", "shell.js"]);
  const files = collectAssets(manifest, ["shell", "inbox"]);
  assert.deepEqual(measureAssets(files, read), {
    raw: files.reduce((sum, file) => sum + read(file).length, 0),
    gzip: files.reduce((sum, file) => sum + gzipSync(read(file)).length, 0)
  });
});

test("missing route or static dependency rejects incomplete evidence", () => {
  assert.throws(() => collectAssets(manifest, ["renamed-route"]), /Missing manifest entry/);
  assert.throws(() => collectAssets({ shell: manifest.shell }, ["shell"]), /shared/);
  assert.throws(() => checkBudgets(manifest, { schema: 1, routes: [] }, read), /Missing route budgets/);
});

test("both compressed and uncompressed route growth fail independently", () => {
  for (const metric of ["raw", "gzip"]) {
    const config = budget();
    config.routes[0][metric] = 1;
    assert.match(checkBudgets(manifest, config, read).failures.join(), new RegExp(`inbox: ${metric}`));
  }
});

test("optional chunks are still gated in the complete build", () => {
  const config = budget();
  config.total = { raw: 3400, gzip: 100000 };
  const result = checkBudgets(manifest, config, read);
  assert.equal(result.rows[0].raw, 3200);
  assert.match(result.failures.join(), /all emitted JS\/CSS: raw 4000 > 3400/);
});

test("invalid ceilings and paths outside dist are rejected", () => {
  const config = budget();
  config.total = { raw: -1, gzip: 1000 };
  assert.throws(() => checkBudgets(manifest, config, read), /Invalid asset budget/);
  assert.throws(() => readBuiltAsset("/build/dist", "../secret"), /outside the build/);
});
