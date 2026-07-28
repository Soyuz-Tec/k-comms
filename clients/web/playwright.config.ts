import { defineConfig, devices } from "@playwright/test";

const liveAudioE2E = process.env.K_COMMS_LIVE_AUDIO_E2E === "true";
const liveVideoE2E = process.env.K_COMMS_LIVE_VIDEO_E2E === "true";
const liveMediaE2E = liveAudioE2E || liveVideoE2E;
const externalServer = process.env.K_COMMS_EXTERNAL_E2E_SERVER === "true";
const mockedBaseURL =
  process.env.K_COMMS_E2E_BASE_URL || "http://127.0.0.1:4178";
const liveMediaBaseURL = liveVideoE2E
  ? process.env.K_COMMS_LIVE_VIDEO_BASE_URL || "http://127.0.0.1:4178"
  : liveAudioE2E
    ? process.env.K_COMMS_LIVE_AUDIO_BASE_URL || "http://127.0.0.1:4178"
  : "http://127.0.0.1:4178";
const liveMediaURL = new URL(liveMediaBaseURL);
const liveMediaPort = liveMediaURL.port || (liveMediaURL.protocol === "https:" ? "443" : "80");

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: "list",
  use: {
    baseURL: liveMediaE2E ? liveMediaBaseURL : mockedBaseURL,
    // Route-mocked tests must not let a registered worker bypass page.route.
    // The dedicated PWA spec explicitly enables service workers.
    serviceWorkers: "block",
    trace: "on-first-retry"
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        ...(liveMediaE2E
          ? {
              launchOptions: {
                args: [
                  "--autoplay-policy=no-user-gesture-required",
                  "--use-fake-device-for-media-stream",
                  "--use-fake-ui-for-media-stream"
                ]
              }
            }
          : {})
      }
    },
    {
      name: "mobile-chromium",
      testIgnore: /live-(audio|video)\.spec\.ts/,
      use: { ...devices["Pixel 7"] }
    },
    {
      name: "webkit",
      testIgnore: /live-(audio|video)\.spec\.ts/,
      use: { ...devices["Desktop Safari"] }
    }
  ],
  webServer: externalServer ? undefined : {
    command: liveMediaE2E
      ? `npm run dev -- --host ${liveMediaURL.hostname} --port ${liveMediaPort}`
      : "npm run dev -- --host 127.0.0.1 --port 4178",
    url: liveMediaE2E
      ? new URL("/app/", liveMediaURL).toString()
      : "http://127.0.0.1:4178/app/",
    env: liveMediaE2E
      ? {
          VITE_DISABLE_REALTIME: "false",
          VITE_PROXY_TARGET:
            (liveVideoE2E ? process.env.K_COMMS_LIVE_VIDEO_API_URL : process.env.K_COMMS_LIVE_AUDIO_API_URL) ||
            process.env.VITE_PROXY_TARGET ||
            "http://127.0.0.1:4000"
        }
      : { VITE_DISABLE_REALTIME: "true" },
    reuseExistingServer: !process.env.CI
  }
});
