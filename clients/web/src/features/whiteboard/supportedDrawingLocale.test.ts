import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { packageSupportedDrawingLocale } from "../../../build/supported-drawing-locale";

describe("supported drawing locale packaging", () => {
  it("keeps the exact maintained production engine and embedded English without unreachable locale imports", () => {
    const source = readFileSync(resolve("node_modules/@excalidraw/excalidraw/dist/prod/index.js"), "utf8");
    const packaged = packageSupportedDrawingLocale(source);
    const map = source.match(/\{"\.\/locales\/[^{}]+\}/)![0];
    expect(packaged).toBe(source.replace(map, "{}"));
    expect(packaged).not.toMatch(/import\("\.\/locales\//);
    expect(() => packageSupportedDrawingLocale(source + "\n")).toThrow(/source changed/);
    expect(() => packageSupportedDrawingLocale(source.replace("./locales/ar-SA", "./locales/changed"))).toThrow(/source changed/);
  });
});
