import { defineConfig, devices } from "@playwright/test";

const liveAudioE2E = process.env.K_COMMS_LIVE_AUDIO_E2E === "true";
const liveVideoE2E = process.env.K_COMMS_LIVE_VIDEO_E2E === "true";
const liveMediaE2E = liveAudioE2E || liveVideoE2E;
const liveWhiteboardE2E =
  process.env.K_COMMS_LIVE_WHITEBOARD_E2E === "true";
const liveBackendE2E = liveMediaE2E || liveWhiteboardE2E;
const externalServer = process.env.K_COMMS_EXTERNAL_E2E_SERVER === "true";
/*
 * WebKit runs in CI only.
 *
 * Smart App Control (Windows) blocks the DLLs in Playwright's WebKit bundle
 * from loading — winldd reports "An Application Control policy has blocked
 * this file" for icutu77.dll, libcurl.dll and libsharpyuv.dll. Every WebKit
 * test then fails at browser launch, before a single assertion runs, which is
 * 21 red results that say nothing about the product. Reinstalling does not
 * help: the files are present and the bundle is complete, the OS simply
 * refuses to load them.
 *
 * CI installs WebKit explicitly (.github/workflows/ci.yml) and sets CI=true,
 * so Safari coverage is preserved where it can actually run. To opt back in on
 * a machine without that policy, set K_COMMS_FORCE_WEBKIT=true.
 */
const runWebKit =
  Boolean(process.env.CI) || process.env.K_COMMS_FORCE_WEBKIT === "true";

// Config is re-evaluated in every worker; only the runner should announce this.
if (!runWebKit && process.env.TEST_WORKER_INDEX === undefined) {
  console.warn(
    "[playwright] WebKit project skipped: Safari coverage runs in CI. " +
      "Set K_COMMS_FORCE_WEBKIT=true to include it locally."
  );
}


const mockedBaseURL =
  process.env.K_COMMS_E2E_BASE_URL || "http://127.0.0.1:4178";
const liveBackendBaseURL = liveVideoE2E
  ? process.env.K_COMMS_LIVE_VIDEO_BASE_URL || "http://127.0.0.1:4178"
  : liveAudioE2E
    ? process.env.K_COMMS_LIVE_AUDIO_BASE_URL || "http://127.0.0.1:4178"
    : process.env.K_COMMS_LIVE_WHITEBOARD_BASE_URL ||
      "http://127.0.0.1:4178";
const liveBackendURL = new URL(liveBackendBaseURL);
const liveBackendPort =
  liveBackendURL.port || (liveBackendURL.protocol === "https:" ? "443" : "80");

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: "list",
  use: {
    baseURL: liveBackendE2E ? liveBackendBaseURL : mockedBaseURL,
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
      /*
       * The product ships two palettes (src/theme.css). axe can only judge the
       * scheme the browser reports, so without this project the dark palette —
       * the default identity — would never be contrast-gated.
       */
      name: "chromium-dark",
      testMatch: /accessibility\.spec\.ts/,
      use: { ...devices["Desktop Chrome"], colorScheme: "dark" }
    },
    {
      name: "mobile-chromium",
      testIgnore: /live-(audio|video)\.spec\.ts/,
      use: { ...devices["Pixel 7"] }
    },
    ...(runWebKit
      ? [
          {
            name: "webkit",
            testIgnore: /live-(audio|video)\.spec\.ts/,
            use: { ...devices["Desktop Safari"] }
          }
        ]
      : [])
  ],
  webServer: externalServer ? undefined : {
    command: liveBackendE2E
      ? `npm run dev -- --host ${liveBackendURL.hostname} --port ${liveBackendPort}`
      : "npm run dev -- --host 127.0.0.1 --port 4178",
    url: liveBackendE2E
      ? new URL("/app/", liveBackendURL).toString()
      : "http://127.0.0.1:4178/app/",
    env: liveBackendE2E
      ? {
          VITE_DISABLE_REALTIME: "false",
          VITE_PROXY_TARGET:
            (liveVideoE2E
              ? process.env.K_COMMS_LIVE_VIDEO_API_URL
              : liveAudioE2E
                ? process.env.K_COMMS_LIVE_AUDIO_API_URL
                : process.env.K_COMMS_LIVE_WHITEBOARD_API_URL) ||
            process.env.VITE_PROXY_TARGET ||
            "http://127.0.0.1:4000"
        }
      : { VITE_DISABLE_REALTIME: "true" },
    reuseExistingServer: !process.env.CI
  }
});
