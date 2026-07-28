/* global Buffer, console, process */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const webRoot = join(scriptDirectory, "..");
const publicRoot = join(webRoot, "public");
const distRoot = join(webRoot, "dist");
const validateOnly = process.argv.includes("--validate");
const manifestFileName = "manifest.webmanifest";
const expectedIcons = new Map([
  ["/app/icons/pwa-192.png", [192, 192, "any"]],
  ["/app/icons/pwa-512.png", [512, 512, "any"]],
  ["/app/icons/pwa-maskable-512.png", [512, 512, "maskable"]]
]);
const appleIconPath = "/app/icons/apple-touch-icon.png";
const manifestLinkHref = "/app/manifest.webmanifest";
const appleIconLinkHref = appleIconPath;

validatePublicAssets();

const workerPath = join(distRoot, "k-comms-sw.js");
if (!existsSync(workerPath)) {
  throw new Error(`Built service worker is missing: ${workerPath}. Run the Vite build first.`);
}

if (!validateOnly) {
  finalizeWorkerRevision(workerPath);
}

validateBuiltAssets(workerPath);
console.log(`${validateOnly ? "Validated" : "Finalized"} PWA assets in ${distRoot}`);

function validatePublicAssets() {
  const manifest = readManifest(join(publicRoot, manifestFileName));
  validateManifest(manifest);
  validateIcons(manifest, publicRoot);

  const offline = readFileSync(join(publicRoot, "offline.html"), "utf8");
  if (/<script(?:\s|>)/i.test(offline)) {
    throw new Error("The offline page must not contain scripts.");
  }
  if (!/<main(?:\s|>)/i.test(offline) || !/<h1(?:\s|>)/i.test(offline)) {
    throw new Error("The offline page must expose a main landmark and a level-one heading.");
  }
}

function finalizeWorkerRevision(workerPath) {
  const configuredRevision = process.env.VITE_K_COMMS_RELEASE_REVISION?.trim() || "development";
  if (!/^[A-Za-z0-9._-]{1,128}$/.test(configuredRevision)) {
    throw new Error("VITE_K_COMMS_RELEASE_REVISION may contain only letters, numbers, dots, underscores, and dashes.");
  }

  const worker = readFileSync(workerPath, "utf8");
  const declaration = /const RELEASE_REVISION = "[^"]+";/;
  if (!declaration.test(worker)) {
    throw new Error("The service worker release revision declaration is missing.");
  }

  const finalized = worker.replace(declaration, `const RELEASE_REVISION = "${configuredRevision}";`);
  writeFileSync(workerPath, finalized);
}

function validateBuiltAssets(workerPath) {
  for (const requiredPath of [
    "index.html",
    manifestFileName,
    "offline.html",
    "offline.css",
    "icons/pwa-192.png",
    "icons/pwa-512.png",
    "icons/pwa-maskable-512.png",
    "icons/apple-touch-icon.png"
  ]) {
    if (!existsSync(join(distRoot, requiredPath))) {
      throw new Error(`Built PWA asset is missing: ${requiredPath}`);
    }
  }

  const worker = readFileSync(workerPath, "utf8");
  const revision = worker.match(/const RELEASE_REVISION = "([^"]+)";/)?.[1];
  if (!revision || revision === "__K_COMMS_RELEASE_REVISION__") {
    throw new Error("The built service worker release revision was not finalized.");
  }

  const builtManifest = readManifest(join(distRoot, manifestFileName));
  validateManifest(builtManifest);
  validateIcons(builtManifest, distRoot);

  const builtIndex = readFileSync(join(distRoot, "index.html"), "utf8");
  if (!builtIndex.includes(`href="${manifestLinkHref}"`)) {
    throw new Error("The built index does not link the PWA manifest.");
  }
  if (!builtIndex.includes(`href="${appleIconLinkHref}"`)) {
    throw new Error("The built index does not link the Apple touch icon.");
  }
}

function readManifest(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function validateManifest(manifest) {
  if (manifest.id !== "/" || manifest.start_url !== "/app/" || manifest.scope !== "/") {
    throw new Error("The PWA manifest must keep id '/', start_url '/app/', and scope '/'.");
  }
  if (manifest.display !== "standalone") {
    throw new Error("The PWA manifest display mode must be standalone.");
  }
  if (manifest.prefer_related_applications !== false || manifest.related_applications?.length !== 0) {
    throw new Error("The PWA manifest must not prefer or advertise app-store applications.");
  }
  if ("screenshots" in manifest) {
    throw new Error("The PWA manifest must not contain real-data screenshots.");
  }

  const manifestIcons = new Map(
    (manifest.icons || []).map((icon) => [icon.src, icon])
  );
  for (const [src, [width, height, purpose]] of expectedIcons) {
    const icon = manifestIcons.get(src);
    if (
      !icon ||
      icon.sizes !== `${width}x${height}` ||
      icon.type !== "image/png" ||
      icon.purpose !== purpose
    ) {
      throw new Error(`Manifest metadata is invalid for ${src}.`);
    }
  }
}

function validateIcons(manifest, root) {
  for (const icon of manifest.icons) {
    const expected = expectedIcons.get(icon.src);
    if (!expected) continue;
    const localPath = icon.src.replace(/^\/app\//, "");
    assertPngDimensions(join(root, localPath), expected[0], expected[1]);
  }
  assertPngDimensions(join(root, appleIconPath.replace(/^\/app\//, "")), 180, 180);
}

function assertPngDimensions(path, expectedWidth, expectedHeight) {
  const image = readFileSync(path);
  const signature = image.subarray(0, 8);
  if (!signature.equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    throw new Error(`${path} is not a PNG file.`);
  }
  const width = image.readUInt32BE(16);
  const height = image.readUInt32BE(20);
  if (width !== expectedWidth || height !== expectedHeight) {
    throw new Error(`${path} must be exactly ${expectedWidth}x${expectedHeight}; found ${width}x${height}.`);
  }
}
