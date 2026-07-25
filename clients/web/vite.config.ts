import { defineConfig, loadEnv } from "vite";
import type { Plugin } from "vite";
import react from "@vitejs/plugin-react";

function guestEntryFallback(): Plugin {
  const install = (server: { middlewares: { use: (handler: (
    request: { url?: string },
    response: unknown,
    next: () => void
  ) => void) => void } }) => {
    server.middlewares.use((request, _response, next) => {
      const [pathname, query] = (request.url || "/").split("?", 2);
      if (pathname === "/join") {
        request.url = `/app/${query ? `?${query}` : ""}`;
      }
      next();
    });
  };

  return {
    name: "k-comms-guest-entry-fallback",
    configureServer: install,
    configurePreviewServer: install
  };
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  const target = env.VITE_PROXY_TARGET || "http://localhost:4000";

  return {
    base: "/app/",
    plugins: [guestEntryFallback(), react()],
    server: {
      host: "0.0.0.0",
      port: 5173,
      proxy: {
        "/api": { target, changeOrigin: true },
        "/health": { target, changeOrigin: true },
        "/socket": { target, changeOrigin: true, ws: true }
      }
    },
    build: {
      outDir: "dist",
      sourcemap: false
    }
  };
});
