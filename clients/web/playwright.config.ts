import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: "list",
  use: {
    baseURL: "http://127.0.0.1:4178",
    trace: "on-first-retry"
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "mobile-chromium", use: { ...devices["Pixel 7"] } }
  ],
  webServer: {
    command: "npm run dev -- --host 127.0.0.1 --port 4178",
    url: "http://127.0.0.1:4178/app/",
    env: { VITE_DISABLE_REALTIME: "true" },
    reuseExistingServer: !process.env.CI
  }
});
