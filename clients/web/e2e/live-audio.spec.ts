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
import type { AccountSession, AudioCall, Conversation, Session, User } from "../src/types";

const enabled = process.env.K_COMMS_LIVE_AUDIO_E2E === "true";
const liveStackURL = process.env.K_COMMS_LIVE_AUDIO_BASE_URL || "http://127.0.0.1:4178";

interface BootstrapResponse extends Session {
  conversation: Conversation;
}

interface DataResponse<T> {
  data: T;
}

interface InvitationResponse {
  invitation_token: string;
}

interface PeerStats {
  bytes: number;
  packets: number;
}

test.use({ trace: "off" });

test.describe("real-stack audio qualification", () => {
  test.describe.configure({ mode: "serial" });
  test.skip(!enabled, "set K_COMMS_LIVE_AUDIO_E2E=true to run against the local K-Comms stack");
  test.setTimeout(120_000);

  test("two humans exchange microphone audio, revoked access is evicted, and the owner ends the room", async ({ browser, request }, testInfo) => {
    const fixture = await provisionDisposableConversation(request);
    const ownerContext = await audioContext(browser, fixture.owner, testInfo);
    const memberContext = await audioContext(browser, fixture.member, testInfo);

    try {
      const ownerPage = await ownerContext.newPage();
      const memberPage = await memberContext.newPage();
      const memberPageErrors: string[] = [];
      memberPage.on("pageerror", (error) => memberPageErrors.push(safePageError(error)));
      const conversationURL = `/app/?conversation=${encodeURIComponent(fixture.conversation.id)}`;

      await Promise.all([ownerPage.goto(conversationURL), memberPage.goto(conversationURL)]);
      await Promise.all([
        expect(ownerPage.getByRole("button", { name: "Start audio call" })).toBeVisible({ timeout: 20_000 }),
        expect(memberPage.getByRole("button", { name: "Start audio call" })).toBeVisible({ timeout: 20_000 })
      ]);

      await joinWithMicrophone(ownerPage, "Start audio call", "Start an audio call");

      await expect(memberPage.getByRole("button", { name: "Join audio call" })).toBeVisible({
        timeout: 20_000
      });
      await joinWithMicrophone(memberPage, "Join audio call", "Join the audio call", memberPageErrors);

      await Promise.all([
        expectParticipantRoster(ownerPage, fixture.owner.user.display_name, fixture.member.user.display_name),
        expectParticipantRoster(memberPage, fixture.member.user.display_name, fixture.owner.user.display_name),
        expectRemoteAudioStream(ownerPage, "owner"),
        expectRemoteAudioStream(memberPage, "member")
      ]);

      const [ownerBaseline, memberBaseline] = await Promise.all([
        inboundAudioStats(ownerPage),
        inboundAudioStats(memberPage)
      ]);

      await Promise.all([
        expectInboundAudioToIncrease(ownerPage, ownerBaseline),
        expectInboundAudioToIncrease(memberPage, memberBaseline)
      ]);

      const activeCallResponse = await request.get(
        `/api/v1/conversations/${encodeURIComponent(fixture.conversation.id)}/call`,
        { headers: authorization(fixture.owner) }
      );
      const activeCall = (await expectJSON<DataResponse<AudioCall>>(activeCallResponse, 200)).data;

      const memberSessionsResponse = await request.get(
        `/api/v1/admin/users/${encodeURIComponent(fixture.member.user.id)}/sessions`,
        { headers: authorization(fixture.owner) }
      );
      const memberSessions = (await expectJSON<DataResponse<AccountSession[]>>(
        memberSessionsResponse,
        200
      )).data;
      const memberSession = memberSessions.find((session) => (
        session.device_id === fixture.member.device.id && !session.revoked_at
      ));
      expect(memberSession, "the provisioned member session should be active").toBeDefined();

      const revocation = await request.delete(
        `/api/v1/admin/users/${encodeURIComponent(fixture.member.user.id)}/sessions/${encodeURIComponent(memberSession!.id)}`,
        {
          headers: authorization(fixture.owner),
          data: { reason: "Live audio revocation qualification" }
        }
      );
      await expectStatus(revocation, 204);

      // This is a whole K-Comms session revocation, not only a call admission
      // revocation. The closed realtime socket forces an authentication retry;
      // once both access and refresh credentials are rejected, the product must
      // remove the authenticated workspace (including the call) and require a
      // fresh sign-in. Call-only removals retain their terminal in-call notice
      // and are covered by AudioCallPanel's component tests.
      await expect(memberPage.getByRole("heading", { name: "Sign in to your workspace" })).toBeVisible({
        timeout: 20_000
      });
      await expect(memberPage.locator(".audio-call-dock")).toHaveCount(0);
      await expect(memberPage.locator('audio[data-k-comms-call-audio="remote"]')).toHaveCount(0);
      await expect.poll(() => allPeerConnectionsClosed(memberPage), { timeout: 20_000 }).toBe(true);

      const ownerRoster = ownerPage.getByRole("list", { name: "Call participants" });
      await expect(ownerRoster.getByRole("listitem")).toHaveCount(1, { timeout: 20_000 });
      await expect(ownerRoster.getByRole("listitem")).toContainText(
        `${fixture.owner.user.display_name} (you)`
      );
      await expect(ownerPage.locator(".audio-call-dock").getByText("Connected", { exact: true })).toBeVisible();
      await expect(ownerPage.getByRole("button", { name: "Mute microphone" })).toBeEnabled();

      const rejectedRejoin = await request.post(
        `/api/v1/conversations/${encodeURIComponent(fixture.conversation.id)}/calls/${encodeURIComponent(activeCall.id)}/join`,
        { headers: authorization(fixture.member) }
      );
      await expectStatus(rejectedRejoin, 401);

      await ownerPage.getByRole("button", { name: "End for everyone" }).click();

      await expect(ownerPage.locator(".audio-call-dock")).toHaveCount(0, {
        timeout: 20_000
      });
      await expect.poll(() => allPeerConnectionsClosed(ownerPage), { timeout: 20_000 }).toBe(true);

      const endedCall = await request.get(
        `/api/v1/conversations/${encodeURIComponent(fixture.conversation.id)}/call`,
        { headers: authorization(fixture.owner) }
      );
      const endedCallPayload = await expectJSON<DataResponse<unknown | null>>(endedCall, 200);
      expect(endedCallPayload.data).toBeNull();
    } finally {
      await Promise.allSettled([ownerContext.close(), memberContext.close()]);
    }
  });
});

async function provisionDisposableConversation(request: APIRequestContext) {
  const suffix = randomUUID().replaceAll("-", "").slice(0, 16);
  const tenantSlug = `audio-e2e-${suffix}`;
  const ownerPassword = strongPassword();
  const memberPassword = strongPassword();

  const bootstrap = await request.post("/api/v1/bootstrap", {
    data: {
      tenant_name: `Audio E2E ${suffix}`,
      tenant_slug: tenantSlug,
      display_name: "Audio Owner",
      email: `audio-owner-${suffix}@example.test`,
      password: ownerPassword
    }
  });
  const owner = withReceivedAt(await expectJSON<BootstrapResponse>(bootstrap, 201));

  const stepUp = await request.post("/api/v1/me/step-up", {
    headers: authorization(owner),
    data: { current_password: ownerPassword }
  });
  await expectStatus(stepUp, 200);

  const invitation = await request.post("/api/v1/admin/invitations", {
    headers: authorization(owner),
    data: {
      email: `audio-member-${suffix}@example.test`,
      role: "member"
    }
  });
  const invitationPayload = await expectJSON<InvitationResponse>(invitation, 201);

  const acceptance = await request.post("/api/v1/invitations/accept", {
    data: {
      token: invitationPayload.invitation_token,
      display_name: "Audio Member",
      password: memberPassword
    }
  });
  const acceptedUser = (await expectJSON<DataResponse<User>>(acceptance, 201)).data;

  const signIn = await request.post("/api/v1/sessions", {
    data: {
      tenant_slug: tenantSlug,
      email: `audio-member-${suffix}@example.test`,
      password: memberPassword,
      device: { name: "Audio E2E member", platform: "playwright" }
    }
  });
  const member = withReceivedAt(await expectJSON<Session>(signIn, 200));

  const conversationResponse = await request.post("/api/v1/conversations", {
    headers: authorization(owner),
    data: {
      kind: "direct",
      visibility: "private",
      member_ids: [acceptedUser.id]
    }
  });
  const conversation = (await expectJSON<DataResponse<Conversation>>(conversationResponse, 201)).data;

  return { owner, member, conversation };
}

async function audioContext(
  browser: Browser,
  session: Session,
  testInfo: TestInfo
) {
  const baseURL = String(testInfo.project.use.baseURL || liveStackURL);
  const context: BrowserContext = await browser.newContext({ baseURL, permissions: ["microphone"] });
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

    Object.defineProperty(window, "__kCommsAudioPeerConnections", {
      configurable: false,
      enumerable: false,
      value: peerConnections
    });
    window.RTCPeerConnection = InstrumentedPeerConnection;
  }, session);
  return context;
}

async function joinWithMicrophone(
  page: Page,
  actionName: string,
  dialogName: string,
  pageErrors: string[] = []
) {
  await page.getByRole("button", { name: actionName }).click();
  const dialog = page.getByRole("dialog", { name: dialogName });
  await expect(dialog).toBeVisible();
  await dialog.getByRole("button", { name: "Join with microphone" }).click();
  await expect.poll(
    async () => {
      const state = await audioJoinState(page);
      return state === "unknown" && pageErrors.length > 0
        ? `runtime-error:${pageErrors.at(-1)}`
        : state;
    },
    { timeout: 20_000 }
  ).toBe("connected");
  await expect(page.getByRole("button", { name: "Mute microphone" })).toBeEnabled();
}

function safePageError(error: Error) {
  return `${error.name}:${error.message}`
    .replace(/[A-Za-z0-9_-]{80,}/g, "[redacted]")
    .replace(/([?&](?:access_)?token=)[^&\s]+/gi, "$1[redacted]")
    .slice(0, 240);
}

async function audioJoinState(page: Page) {
  return page.evaluate(() => {
    if (document.querySelector(".audio-call-dock")) return "connected";
    if (document.querySelector(".auth-page")) return "signed-out";
    const error = document.querySelector(".audio-call-terminal-notice[role='alert']");
    if (error) return `join-error:${error.textContent || "unspecified"}`;
    if (document.querySelector(".audio-prejoin-dialog")) return "prejoin";
    if (document.querySelector(".audio-call-control")) return "workspace-idle";
    if (document.querySelector("#root:empty")) return "empty-root";
    return "unknown";
  });
}

async function expectParticipantRoster(page: Page, localName: string, remoteName: string) {
  const roster = page.getByRole("list", { name: "Call participants" });
  await expect(roster.getByRole("listitem")).toHaveCount(2, { timeout: 20_000 });
  await expect(roster.getByRole("listitem").filter({ hasText: `${localName} (you)` })).toContainText(
    "Microphone on"
  );
  await expect(roster.getByRole("listitem").filter({ hasText: remoteName })).toContainText(
    "Microphone on"
  );
}

async function expectRemoteAudioStream(page: Page, participant: string) {
  const audio = page.locator('audio[data-k-comms-call-audio="remote"]');
  await expect(audio, `${participant} should attach one remote audio element`).toHaveCount(1, {
    timeout: 20_000
  });
  await expect
    .poll(
      () =>
        audio.evaluate((element) => {
          const stream = (element as HTMLAudioElement).srcObject;
          return (
            stream instanceof MediaStream &&
            stream.getAudioTracks().some((track) => track.readyState === "live")
          );
        }),
      { timeout: 20_000 }
    )
    .toBe(true);
}

async function inboundAudioStats(page: Page): Promise<PeerStats> {
  return page.evaluate(async () => {
    const connections = (
      window as typeof window & { __kCommsAudioPeerConnections?: RTCPeerConnection[] }
    ).__kCommsAudioPeerConnections || [];
    const result = { bytes: 0, packets: 0 };

    for (const connection of connections) {
      const reports = await connection.getStats();
      reports.forEach((report) => {
        const mediaKind = report.kind || report.mediaType;
        if (report.type === "inbound-rtp" && mediaKind === "audio" && !report.isRemote) {
          result.bytes += Number(report.bytesReceived || 0);
          result.packets += Number(report.packetsReceived || 0);
        }
      });
    }
    return result;
  });
}

async function expectInboundAudioToIncrease(page: Page, baseline: PeerStats) {
  await expect
    .poll(
      async () => {
        const current = await inboundAudioStats(page);
        return current.bytes > baseline.bytes && current.packets > baseline.packets;
      },
      { timeout: 20_000, intervals: [500, 1_000, 2_000] }
    )
    .toBe(true);
}

async function allPeerConnectionsClosed(page: Page) {
  return page.evaluate(() => {
    const connections = (
      window as typeof window & { __kCommsAudioPeerConnections?: RTCPeerConnection[] }
    ).__kCommsAudioPeerConnections || [];
    return (
      connections.length > 0 &&
      connections.every((connection) =>
        ["closed", "disconnected", "failed"].includes(connection.connectionState)
      )
    );
  });
}

function authorization(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` };
}

function withReceivedAt<T extends Session>(session: T): T {
  return { ...session, received_at: Date.now() };
}

function strongPassword() {
  return `Kc!${randomUUID()}Aa9`;
}

async function expectStatus(response: APIResponse, expectedStatus: number) {
  if (response.status() !== expectedStatus) {
    throw new Error(`Live audio setup request failed with status ${response.status()}`);
  }
}

async function expectJSON<T>(response: APIResponse, expectedStatus: number): Promise<T> {
  await expectStatus(response, expectedStatus);
  return (await response.json()) as T;
}
