import { createHash } from "node:crypto";
import type { Plugin } from "vite";

// Excalidraw 0.18.1, exact npm integrity lock. The host supports English and
// exposes no vendor language picker. Its English translations are embedded.
export const DRAWING_PRODUCTION_SHA256 = "7f651063487849c79a8cdedc3aa6bd04c6b0c717ee63959116f1f12dbc0a51b8";
export function packageSupportedDrawingLocale(source: string): string {
  if (createHash("sha256").update(source).digest("hex") !== DRAWING_PRODUCTION_SHA256) throw new Error("Excalidraw production source changed; review supported locale packaging before release.");
  const maps = [...source.matchAll(/\{"\.\/locales\/[^{}]+\}/g)];
  if (maps.length !== 1) throw new Error("Excalidraw locale import map changed.");
  const map = maps[0]![0];
  const entries = map.match(/"\.\/locales\/[^"]+\.json":\(\)=>import\("\.\/locales\/[^"]+\.js"\)/g);
  if (entries?.length !== 55 || map !== `{${entries.join(",")}}`) throw new Error("Excalidraw locale imports changed; refusing partial packaging.");
  // Remove unsupported import graph at compilation, preserving the maintained
  // drawing engine and inline English translations. The budget checker still
  // measures EVERY emitted JS/CSS asset without exclusion or changed ceilings.
  return source.replace(map, "{}");
}
export function supportedDrawingLocale(): Plugin {
  return {
    name: "k-comms-supported-drawing-locale",
    enforce: "pre",
    transform(source, id) {
      if (!id.split("?", 1)[0]?.endsWith("/@excalidraw/excalidraw/dist/prod/index.js")) return;
      return { code: packageSupportedDrawingLocale(source), map: null };
    }
  };
}
