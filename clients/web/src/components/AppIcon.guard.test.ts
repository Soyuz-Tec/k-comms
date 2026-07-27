import { readdirSync, readFileSync } from "node:fs";
import { extname, join, relative, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const sourceRoot = resolve(process.cwd(), "src");
const productionExtensions = new Set([".css", ".ts", ".tsx"]);
const legacyControlGlyphs = String.fromCodePoint(
  0x00d7,
  0xff0b,
  0x25c7,
  0x2304,
  0x2315,
  0x25c9,
  0x25cb,
  0x2726,
  0x2301,
  0x25a4,
  0x21bb,
  0x25d6,
  0x2662,
  0x25cf,
  0x25b1,
  0x2261,
  0x21aa,
  0x21a9,
  0x2193,
  0x2190,
  0x2039,
  0x2606,
  0x2713
);

interface SourceFile {
  path: string;
  source: string;
}

function productionSourceFiles(directory = sourceRoot): SourceFile[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return productionSourceFiles(path);
    if (!productionExtensions.has(extname(entry.name)) || entry.name.includes(".test.")) return [];
    return [{ path: relative(sourceRoot, path).replaceAll("\\", "/"), source: readFileSync(path, "utf8") }];
  });
}

describe("application icon system", () => {
  it("keeps production icons behind the Lucide AppIcon adapter", () => {
    const failures: string[] = [];

    for (const file of productionSourceFiles()) {
      if (/<svg\b/i.test(file.source)) failures.push(`${file.path}: hand-authored SVG`);
      if (file.path !== "components/AppIcon.tsx" && /from\s+["']lucide-react["']/.test(file.source)) {
        failures.push(`${file.path}: direct lucide-react import`);
      }

      for (const glyph of legacyControlGlyphs) {
        if (file.source.includes(glyph)) failures.push(`${file.path}: legacy control glyph ${JSON.stringify(glyph)}`);
      }

      if (file.path.endsWith(".css")) {
        for (const match of file.source.matchAll(/^\s*content\s*:\s*(["'])(.*?)\1/gm)) {
          if (match[2]) failures.push(`${file.path}: generated icon content ${JSON.stringify(match[2])}`);
        }
      }
    }

    expect(failures).toEqual([]);
  });
});
