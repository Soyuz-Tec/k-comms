import { expect, test } from "@playwright/test";
import type {
  APIRequestContext,
  APIResponse,
  Browser,
  BrowserContext,
  Page,
  TestInfo
} from "@playwright/test";
import { randomUUID } from "node:crypto";
import type { Conversation, Session, User } from "../src/types";

const enabled = process.env.K_COMMS_LIVE_VIDEO_E2E === "true";
const liveStackURL = process.env.K_COMMS_LIVE_VIDEO_BASE_URL || "http://127.0.0.1:4178";

interface BootstrapResponse extends Session {
  conversation: Conversation;
}

interface DataResponse<T> {
  data: T;
}

interface InvitationResponse {
  invitation_token: string;
}

interface VideoStats {
  bytes: number;
  packets: number;
  frames: number;
}

test.use({ trace: "off" });

test.describe("real-stack video qualification", () => {
  test.describe.configure({ mode: "serial" });
  test.skip(!enabled, "set K_COMMS_LIVE_VIDEO_E2E=true to run against the local K-Comms stack");
  test.setTimeout(180_000);

  test("direct and three-person group calls exchange camera video and terminate cleanly", async ({ browser, request }, testInfo) => {
    const fixture = await provisionVideoWorkspace(request);
    const ownerContext = await videoContext(browser, fixture.owner, testInfo);
    const memberOneContext = await videoContext(browser, fixture.memberOne, testInfo);
    const memberTwoContext = await videoContext(browser, fixture.memberTwo, testInfo);

    try {
      const ownerPage = await ownerContext.newPage();
      const memberOnePage = await memberOneContext.newPage();
      const memberTwoPage = await memberTwoContext.newPage();

      await qualifyConversation(
        fixture.direct,
        [
          { page: ownerPage, action: "Start video call", dialog: "Start a video call" },
          { page: memberOnePage, action: "Join video call", dialog: "Join the video call" }
        ]
      );

      await qualifyConversation(
        fixture.group,
        [
          { page: ownerPage, action: "Start video call", dialog: "Start a video call" },
          { page: memberOnePage, action: "Join video call", dialog: "Join the video call" },
          { page: memberTwoPage, action: "Join video call", dialog: "Join the video call" }
        ]
      );
    } finally {
      await Promise.allSettled([ownerContext.close(), memberOneContext.close(), memberTwoContext.close()]);
    }
  });
});

async function qualifyConversation(
  conversation: Conversation,
  participants: Array<{ page: Page; action: "Start video call" | "Join video call"; dialog: "Start a video call" | "Join the video call" }>
) {
  const url = `/app/?conversation=${encodeURIComponent(conversation.id)}`;
  await Promise.all(participants.map(({ page }) => page.goto(url)));
  await expect(participants[0]!.page.getByRole("button", { name: "Start video call" })).toBeVisible({ timeout: 20_000 });

  await joinWithCamera(participants[0]!.page, participants[0]!.action, participants[0]!.dialog);
  for (const participant of participants.slice(1)) {
    await expect(participant.page.getByRole("button", { name: "Join video call" })).toBeVisible({ timeout: 20_000 });
    await joinWithCamera(participant.page, participant.action, participant.dialog);
  }

  await Promise.all(participants.map(({ page }) => expectRemoteVideoStreams(page, participants.length - 1)));
  const baselines = await Promise.all(participants.map(({ page }) => inboundVideoStats(page)));
  await Promise.all(participants.map(({ page }, index) => expectInboundVideoToIncrease(page, baselines[index]!)));

  if (participants.length >= 3) {
    await qualifyScreenShare(participants[0]!.page, participants.slice(1).map(({ page }) => page));
  }

  await participants[0]!.page.getByRole("button", { name: "End for everyone" }).click();
  await Promise.all(participants.map(async ({ page }) => {
    await expect(page.locator(".audio-call-dock")).toHaveCount(0, { timeout: 20_000 });
    await expect(page.locator('video[data-k-comms-call-video]')).toHaveCount(0);
    await expect.poll(() => allPeerConnectionsClosed(page), { timeout: 20_000 }).toBe(true);
  }));
}

async function qualifyScreenShare(ownerPage: Page, remotePages: Page[]) {
  await ownerPage.getByRole("button", { name: "Share screen" }).click();
  await expect(ownerPage.getByRole("button", { name: "Stop sharing screen" })).toBeEnabled({ timeout: 20_000 });
  await expect(ownerPage.locator('video[data-k-comms-call-video="local"][data-source="screen_share"]')).toHaveCount(1, { timeout: 20_000 });

  await Promise.all(remotePages.map(async (page) => {
    const screen = page.locator('video[data-k-comms-call-video="remote"][data-source="screen_share"]');
    await expect(screen).toHaveCount(1, { timeout: 20_000 });
    await expect.poll(() => remoteScreenShareIsLive(page), { timeout: 20_000 }).toBe(true);
  }));

  const baselines = await Promise.all(remotePages.map((page) => inboundScreenShareStats(page)));
  await Promise.all(remotePages.map((page, index) => expectInboundScreenShareToIncrease(page, baselines[index]!)));

  await ownerPage.getByRole("button", { name: "Stop sharing screen" }).click();
  await expect(ownerPage.locator('video[data-k-comms-call-video][data-source="screen_share"]')).toHaveCount(0, { timeout: 20_000 });
  await Promise.all(remotePages.map((page) => (
    expect(page.locator('video[data-k-comms-call-video][data-source="screen_share"]')).toHaveCount(0, { timeout: 20_000 })
  )));
}

async function joinWithCamera(page: Page, action: string, dialogName: string) {
  await page.getByRole("button", { name: action }).click();
  const dialog = page.getByRole("dialog", { name: dialogName });
  await expect(dialog).toBeVisible();
  await dialog.getByRole("checkbox", { name: "Use camera when I join" }).check();
  await expect(dialog.getByLabel("Camera preview")).toBeVisible({ timeout: 20_000 });
  await dialog.getByRole("button", { name: "Join video call" }).click();
  await expect(page.locator(".video-call-dock").getByText("Connected", { exact: true })).toBeVisible({ timeout: 20_000 });
  await expect(page.getByRole("button", { name: "Turn camera off" })).toBeEnabled();
}

async function expectRemoteVideoStreams(page: Page, expected: number) {
  const videos = page.locator('video[data-k-comms-call-video="remote"][data-source="camera"]');
  await expect(videos).toHaveCount(expected, { timeout: 20_000 });
  await expect.poll(async () => videos.evaluateAll((elements) => elements.every((element) => {
    const stream = (element as HTMLVideoElement).srcObject;
    return stream instanceof MediaStream && stream.getVideoTracks().some((track) => track.readyState === "live");
  })), { timeout: 20_000 }).toBe(true);
}

async function videoContext(browser: Browser, session: Session, testInfo: TestInfo) {
  const baseURL = String(testInfo.project.use.baseURL || liveStackURL);
  const context: BrowserContext = await browser.newContext({ baseURL, permissions: ["camera", "microphone"] });
  await context.addInitScript((value: Session) => {
    sessionStorage.setItem("k-comms.session.v1", JSON.stringify(value));
    const peerConnections: RTCPeerConnection[] = [];
    const NativePeerConnection = window.RTCPeerConnection;
    class InstrumentedPeerConnection extends NativePeerConnection {
      constructor(...args: ConstructorParameters<typeof RTCPeerConnection>) {
        super(...args);
        peerConnections.push(this);
      }
    }
    Object.defineProperty(window, "__kCommsVideoPeerConnections", { configurable: false, enumerable: false, value: peerConnections });
    window.RTCPeerConnection = InstrumentedPeerConnection;

    const screenCaptureTimers = new Set<number>();
    Object.defineProperty(navigator.mediaDevices, "getDisplayMedia", {
      configurable: true,
      value: async () => {
        const canvas = document.createElement("canvas");
        canvas.width = 960;
        canvas.height = 540;
        const context = canvas.getContext("2d");
        if (!context) throw new Error("Canvas screen-share source is unavailable");
        let frame = 0;
        const draw = () => {
          frame += 1;
          context.fillStyle = `hsl(${frame % 360} 55% 28%)`;
          context.fillRect(0, 0, canvas.width, canvas.height);
          context.fillStyle = "white";
          context.font = "700 64px sans-serif";
          context.fillText(`K-Comms screen ${frame}`, 60, 280);
          context.fillStyle = "#8fd69a";
          context.fillRect(60 + ((frame * 11) % 700), 360, 180, 40);
        };
        draw();
        const timer = window.setInterval(draw, 40);
        screenCaptureTimers.add(timer);
        const stream = canvas.captureStream(25);
        for (const track of stream.getTracks()) {
          const nativeStop = track.stop.bind(track);
          track.stop = () => {
            window.clearInterval(timer);
            screenCaptureTimers.delete(timer);
            nativeStop();
          };
        }
        return stream;
      }
    });
    window.addEventListener("pagehide", () => {
      screenCaptureTimers.forEach((timer) => window.clearInterval(timer));
      screenCaptureTimers.clear();
    });
  }, session);
  return context;
}

async function remoteScreenShareIsLive(page: Page) {
  return page.evaluate(() => {
    const element = document.querySelector<HTMLVideoElement>('video[data-k-comms-call-video="remote"][data-source="screen_share"]');
    const stream = element?.srcObject;
    return stream instanceof MediaStream && stream.getVideoTracks().some((track) => track.readyState === "live");
  });
}

async function inboundScreenShareStats(page: Page): Promise<VideoStats> {
  return page.evaluate(async () => {
    const element = document.querySelector<HTMLVideoElement>('video[data-k-comms-call-video="remote"][data-source="screen_share"]');
    const stream = element?.srcObject;
    const remoteTrack = stream instanceof MediaStream ? stream.getVideoTracks()[0] : undefined;
    if (!remoteTrack) return { bytes: 0, packets: 0, frames: 0 };
    const connections = (window as typeof window & { __kCommsVideoPeerConnections?: RTCPeerConnection[] }).__kCommsVideoPeerConnections || [];
    const result = { bytes: 0, packets: 0, frames: 0 };
    for (const connection of connections) {
      for (const receiver of connection.getReceivers()) {
        if (receiver.track?.id !== remoteTrack.id) continue;
        const reports = await receiver.getStats();
        reports.forEach((report) => {
          const mediaKind = report.kind || report.mediaType;
          if (report.type === "inbound-rtp" && mediaKind === "video") {
            result.bytes += Number(report.bytesReceived || 0);
            result.packets += Number(report.packetsReceived || 0);
            result.frames += Number(report.framesDecoded || report.framesReceived || 0);
          }
        });
      }
    }
    return result;
  });
}

async function expectInboundScreenShareToIncrease(page: Page, baseline: VideoStats) {
  await expect.poll(async () => {
    const current = await inboundScreenShareStats(page);
    return current.bytes > baseline.bytes && current.packets > baseline.packets && current.frames > baseline.frames;
  }, { timeout: 30_000, intervals: [500, 1_000, 2_000] }).toBe(true);
}

async function inboundVideoStats(page: Page): Promise<VideoStats> {
  return page.evaluate(async () => {
    const connections = (window as typeof window & { __kCommsVideoPeerConnections?: RTCPeerConnection[] }).__kCommsVideoPeerConnections || [];
    const result = { bytes: 0, packets: 0, frames: 0 };
    for (const connection of connections) {
      const reports = await connection.getStats();
      reports.forEach((report) => {
        const mediaKind = report.kind || report.mediaType;
        if (report.type === "inbound-rtp" && mediaKind === "video" && !report.isRemote) {
          result.bytes += Number(report.bytesReceived || 0);
          result.packets += Number(report.packetsReceived || 0);
          result.frames += Number(report.framesDecoded || report.framesReceived || 0);
        }
      });
    }
    return result;
  });
}

async function expectInboundVideoToIncrease(page: Page, baseline: VideoStats) {
  await expect.poll(async () => {
    const current = await inboundVideoStats(page);
    return current.bytes > baseline.bytes && current.packets > baseline.packets && current.frames > baseline.frames;
  }, { timeout: 30_000, intervals: [500, 1_000, 2_000] }).toBe(true);
}

async function allPeerConnectionsClosed(page: Page) {
  return page.evaluate(() => {
    const connections = (window as typeof window & { __kCommsVideoPeerConnections?: RTCPeerConnection[] }).__kCommsVideoPeerConnections || [];
    return connections.length > 0 && connections.every((connection) => ["closed", "disconnected", "failed"].includes(connection.connectionState));
  });
}

async function provisionVideoWorkspace(request: APIRequestContext) {
  const suffix = randomUUID().replaceAll("-", "").slice(0, 16);
  const tenantSlug = `video-e2e-${suffix}`;
  const ownerPassword = strongPassword();
  const memberOnePassword = strongPassword();
  const memberTwoPassword = strongPassword();
  const bootstrap = await request.post("/api/v1/bootstrap", { data: { tenant_name: `Video E2E ${suffix}`, tenant_slug: tenantSlug, display_name: "Video Owner", email: `video-owner-${suffix}@example.test`, password: ownerPassword } });
  const owner = withReceivedAt(await expectJSON<BootstrapResponse>(bootstrap, 201));
  await expectStatus(await request.post("/api/v1/me/step-up", { headers: authorization(owner), data: { current_password: ownerPassword } }), 200);

  const memberOne = await inviteAndSignIn(request, owner, tenantSlug, suffix, "one", "Video Member One", memberOnePassword);
  const memberTwo = await inviteAndSignIn(request, owner, tenantSlug, suffix, "two", "Video Member Two", memberTwoPassword);
  const direct = await createConversation(request, owner, "direct", [memberOne.user.id]);
  const group = await createConversation(request, owner, "group", [memberOne.user.id, memberTwo.user.id]);
  return { owner, memberOne, memberTwo, direct, group };
}

async function inviteAndSignIn(request: APIRequestContext, owner: Session, tenantSlug: string, suffix: string, id: string, displayName: string, password: string) {
  const email = `video-member-${id}-${suffix}@example.test`;
  const invitation = await request.post("/api/v1/admin/invitations", { headers: authorization(owner), data: { email, role: "member" } });
  const token = (await expectJSON<InvitationResponse>(invitation, 201)).invitation_token;
  const acceptance = await request.post("/api/v1/invitations/accept", { data: { token, display_name: displayName, password } });
  await expectJSON<DataResponse<User>>(acceptance, 201);
  const signIn = await request.post("/api/v1/sessions", { data: { tenant_slug: tenantSlug, email, password, device: { name: `${displayName} browser`, platform: "playwright" } } });
  return withReceivedAt(await expectJSON<Session>(signIn, 200));
}

async function createConversation(request: APIRequestContext, owner: Session, kind: "direct" | "group", memberIds: string[]) {
  const response = await request.post("/api/v1/conversations", { headers: authorization(owner), data: { kind, visibility: "private", member_ids: memberIds, ...(kind === "group" ? { title: "Video Group" } : {}) } });
  return (await expectJSON<DataResponse<Conversation>>(response, 201)).data;
}

function authorization(session: Session) { return { Authorization: `Bearer ${session.access_token}` }; }
function withReceivedAt<T extends Session>(session: T): T { return { ...session, received_at: Date.now() }; }
function strongPassword() { return `Kc!${randomUUID()}Aa9`; }

async function expectStatus(response: APIResponse, expectedStatus: number) {
  if (response.status() !== expectedStatus) throw new Error(`Live video setup request failed with status ${response.status()}`);
}

async function expectJSON<T>(response: APIResponse, expectedStatus: number): Promise<T> {
  await expectStatus(response, expectedStatus);
  return (await response.json()) as T;
}
