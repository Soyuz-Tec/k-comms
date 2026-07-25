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

      const memberAudioAction = memberPage.getByRole("button", {
        name: /^(Start|Join) audio call$/
      });
      await expect(memberAudioAction).toBeVisible({
        timeout: 20_000
      });
      await joinWithMicrophone(
        memberPage,
        /^(Start|Join) audio call$/,
        "Join the audio call",
        memberPageErrors
      );

      await Promise.all([
        expectParticipantRoster(
          ownerPage,
          fixture.owner.user.display_name,
          [fixture.member.user.display_name]
        ),
        expectParticipantRoster(
          memberPage,
          fixture.member.user.display_name,
          [fixture.owner.user.display_name]
        ),
        expectRemoteAudioStreams(ownerPage, "owner", 1),
        expectRemoteAudioStreams(memberPage, "member", 1)
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
      // remove the authenticated workspace (including the call). Signed-out
      // `/app` now routes to the account-optional instant-room front door;
      // explicit account authentication remains available at `/sign-in`.
      await expect(memberPage).toHaveURL(/\/$/, { timeout: 20_000 });
      await expect(memberPage.locator(".app-shell")).toHaveCount(0);
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

  test("three humans exchange microphone audio in a group and the owner ends the room", async ({ browser, request }, testInfo) => {
    const fixture = await provisionDisposableGroupConversation(request);
    const ownerContext = await audioContext(browser, fixture.owner, testInfo);
    const memberOneContext = await audioContext(browser, fixture.memberOne, testInfo);
    const memberTwoContext = await audioContext(browser, fixture.memberTwo, testInfo);

    try {
      const ownerPage = await ownerContext.newPage();
      const memberOnePage = await memberOneContext.newPage();
      const memberTwoPage = await memberTwoContext.newPage();
      const pages = [ownerPage, memberOnePage, memberTwoPage];
      const conversationURL = `/app/?conversation=${encodeURIComponent(fixture.conversation.id)}`;

      await Promise.all(pages.map((page) => page.goto(conversationURL)));
      await Promise.all(pages.map((page) => (
        expect(page.getByRole("button", { name: "Start audio call" })).toBeVisible({
          timeout: 20_000
        })
      )));

      await joinWithMicrophone(ownerPage, "Start audio call", "Start an audio call");
      for (const memberPage of [memberOnePage, memberTwoPage]) {
        await expect(memberPage.getByRole("button", {
          name: /^(Start|Join) audio call$/
        })).toBeVisible({
          timeout: 20_000
        });
        await joinWithMicrophone(
          memberPage,
          /^(Start|Join) audio call$/,
          "Join the audio call"
        );
      }

      await Promise.all([
        expectParticipantRoster(ownerPage, fixture.owner.user.display_name, [
          fixture.memberOne.user.display_name,
          fixture.memberTwo.user.display_name
        ]),
        expectParticipantRoster(memberOnePage, fixture.memberOne.user.display_name, [
          fixture.owner.user.display_name,
          fixture.memberTwo.user.display_name
        ]),
        expectParticipantRoster(memberTwoPage, fixture.memberTwo.user.display_name, [
          fixture.owner.user.display_name,
          fixture.memberOne.user.display_name
        ]),
        expectRemoteAudioStreams(ownerPage, "owner", 2),
        expectRemoteAudioStreams(memberOnePage, "first member", 2),
        expectRemoteAudioStreams(memberTwoPage, "second member", 2)
      ]);

      const baselines = await Promise.all(pages.map((page) => inboundAudioStats(page)));
      await Promise.all(
        pages.map((page, index) => expectInboundAudioToIncrease(page, baselines[index]!))
      );

      await ownerPage.getByRole("button", { name: "End for everyone" }).click();
      await Promise.all(pages.map(async (page) => {
        await expect(page.locator(".audio-call-dock")).toHaveCount(0, { timeout: 20_000 });
        await expect(page.locator('audio[data-k-comms-call-audio="remote"]')).toHaveCount(0);
        await expect.poll(() => allPeerConnectionsClosed(page), { timeout: 20_000 }).toBe(true);
      }));

      const endedCall = await request.get(
        `/api/v1/conversations/${encodeURIComponent(fixture.conversation.id)}/call`,
        { headers: authorization(fixture.owner) }
      );
      const endedCallPayload = await expectJSON<DataResponse<unknown | null>>(endedCall, 200);
      expect(endedCallPayload.data).toBeNull();
    } finally {
      await Promise.allSettled([
        endActiveCallIfPresent(request, fixture.owner, fixture.conversation.id),
        ownerContext.close(),
        memberOneContext.close(),
        memberTwoContext.close()
      ]);
    }
  });
});

async function provisionDisposableConversation(request: APIRequestContext) {
  const suffix = randomUUID().replaceAll("-", "").slice(0, 16);
  const { owner, tenantSlug } = await provisionAudioOwner(request, suffix);
  const invitedMember = await inviteAndSignInAudioMember(
    request,
    owner,
    tenantSlug,
    suffix,
    "member",
    "Audio Member"
  );

  const conversationResponse = await request.post("/api/v1/conversations", {
    headers: authorization(owner),
    data: {
      kind: "direct",
      visibility: "private",
      member_ids: [invitedMember.user.id]
    }
  });
  const conversation = (await expectJSON<DataResponse<Conversation>>(conversationResponse, 201)).data;

  return { owner, member: invitedMember.session, conversation };
}

async function provisionDisposableGroupConversation(request: APIRequestContext) {
  const suffix = randomUUID().replaceAll("-", "").slice(0, 16);
  const { owner, tenantSlug } = await provisionAudioOwner(request, suffix);
  const memberOne = await inviteAndSignInAudioMember(
    request,
    owner,
    tenantSlug,
    suffix,
    "one",
    "Audio Member One"
  );
  const memberTwo = await inviteAndSignInAudioMember(
    request,
    owner,
    tenantSlug,
    suffix,
    "two",
    "Audio Member Two"
  );

  const conversationResponse = await request.post("/api/v1/conversations", {
    headers: authorization(owner),
    data: {
      kind: "group",
      visibility: "private",
      title: "Audio Group",
      member_ids: [memberOne.user.id, memberTwo.user.id]
    }
  });
  const conversation = (await expectJSON<DataResponse<Conversation>>(conversationResponse, 201)).data;

  return {
    owner,
    memberOne: memberOne.session,
    memberTwo: memberTwo.session,
    conversation
  };
}

async function provisionAudioOwner(request: APIRequestContext, suffix: string) {
  const tenantSlug = `audio-e2e-${suffix}`;
  const ownerPassword = strongPassword();
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
  return { owner, tenantSlug };
}

async function inviteAndSignInAudioMember(
  request: APIRequestContext,
  owner: Session,
  tenantSlug: string,
  suffix: string,
  label: string,
  displayName: string
) {
  const email = `audio-member-${label}-${suffix}@example.test`;
  const password = strongPassword();
  const invitation = await request.post("/api/v1/admin/invitations", {
    headers: authorization(owner),
    data: { email, role: "member" }
  });
  const invitationPayload = await expectJSON<InvitationResponse>(invitation, 201);
  const acceptance = await request.post("/api/v1/invitations/accept", {
    data: {
      token: invitationPayload.invitation_token,
      display_name: displayName,
      password
    }
  });
  const user = (await expectJSON<DataResponse<User>>(acceptance, 201)).data;
  const signIn = await request.post("/api/v1/sessions", {
    data: {
      tenant_slug: tenantSlug,
      email,
      password,
      device: { name: `${displayName} browser`, platform: "playwright" }
    }
  });
  const session = withReceivedAt(await expectJSON<Session>(signIn, 200));
  return { session, user };
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
  actionName: string | RegExp,
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
  await expandCall(page);
  await expect(page.getByRole("button", { name: "Mute microphone" })).toBeEnabled();
}

async function expandCall(page: Page) {
  const showCall = page.getByRole("button", { name: "Show call" });
  const minimizeCall = page.getByRole("button", { name: "Minimize" });
  await expect(
    showCall.or(minimizeCall),
    "audio calls should expose either their compact or expanded controls"
  ).toBeVisible({ timeout: 20_000 });
  if (await showCall.isVisible()) await showCall.click();
  await expect(minimizeCall).toBeVisible();
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

async function expectParticipantRoster(page: Page, localName: string, remoteNames: string[]) {
  const roster = page.getByRole("list", { name: "Call participants" });
  await expect(roster.getByRole("listitem")).toHaveCount(remoteNames.length + 1, {
    timeout: 20_000
  });
  await expect(roster.getByRole("listitem").filter({ hasText: `${localName} (you)` })).toContainText(
    "Microphone on"
  );
  for (const remoteName of remoteNames) {
    await expect(roster.getByRole("listitem").filter({ hasText: remoteName })).toContainText(
      "Microphone on"
    );
  }
}

async function expectRemoteAudioStreams(page: Page, participant: string, expectedCount: number) {
  const audio = page.locator('audio[data-k-comms-call-audio="remote"]');
  await expect(
    audio,
    `${participant} should attach ${expectedCount} remote audio element(s)`
  ).toHaveCount(expectedCount, { timeout: 20_000 });
  await expect
    .poll(
      () =>
        audio.evaluateAll((elements) => elements.every((element) => {
          const stream = (element as HTMLAudioElement).srcObject;
          return (
            stream instanceof MediaStream &&
            stream.getAudioTracks().some((track) => track.readyState === "live")
          );
        })),
      { timeout: 20_000 }
    )
    .toBe(true);
}

async function endActiveCallIfPresent(
  request: APIRequestContext,
  owner: Session,
  conversationId: string
) {
  const activeCallResponse = await request.get(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/call`,
    { headers: authorization(owner) }
  );
  if (activeCallResponse.status() !== 200) return;

  const activeCall = (await activeCallResponse.json() as DataResponse<AudioCall | null>).data;
  if (!activeCall) return;

  const endCallResponse = await request.post(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls/${encodeURIComponent(activeCall.id)}/end`,
    { headers: authorization(owner) }
  );
  await expectStatus(endCallResponse, 200);
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
