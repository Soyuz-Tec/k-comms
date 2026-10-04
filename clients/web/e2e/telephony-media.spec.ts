import { createHmac, randomUUID } from "node:crypto";
import type { Page } from "@playwright/test";
import type { Room } from "livekit-client";
import type * as LiveKit from "livekit-client";
import { expect, test, mockServiceStatus } from "./fixtures";
import { installWorkspace, userId } from "./mobile-ui-support";
import type { PhoneCall } from "../src/features/telephony/types";

// This qualifies the new browser media boundary against a local LiveKit server.
// HTTP call state is synthetic; this test does not qualify a SIP carrier/PSTN.
test.skip(process.env.K_COMMS_LIVE_PHONE_MEDIA_E2E !== "true", "enable K_COMMS_LIVE_PHONE_MEDIA_E2E with local LiveKit and fake microphone browser flags");
test.setTimeout(90_000);
test.use({ trace: "off" });

test("phone audio exchanges real LiveKit media and hangup releases every microphone track", async ({ page, context }) => {
  await installWorkspace(page);
  await instrument(page);
  const roomName = `phone-browser-qualification-${randomUUID()}`;
  const number = { id: "synthetic-line", phone_number: "+14155550123", extension: "101", user_id: userId };
  let started = false;
  let call: PhoneCall = { id: "synthetic-call", direction: "outbound", status: "ringing", from_number: number.phone_number, to_number: "+14155550199", extension: "101", started_at: new Date().toISOString(), answered_at: null, ended_at: null, connected_seconds: 0, can_answer: false, can_join: true, can_end: true, active_on_this_device: true };
  const serverUrl = process.env.K_COMMS_PHONE_MEDIA_URL ?? "ws://127.0.0.1:7880";
  const credential = { server_url: serverUrl, participant_token: token(roomName, "phone-browser"), expires_in: 600 };
  await page.route("**/api/v1/telephony/config", (route) => route.fulfill({ json: { data: { enabled: true, configured: true, provider: "livekit_sip", number, can_manage: true } } }));
  await page.route("**/api/v1/telephony/calls?**", (route) => {
    const active = new URL(route.request().url()).searchParams.get("scope") === "active";
    return route.fulfill({ json: { data: !started || (active && call.status === "ended") ? [] : [call], page: { limit: 30, has_more: false, next_cursor: null } } });
  });
  await page.route("**/api/v1/telephony/calls", (route) => {
    started = true;
    expect(route.request().postDataJSON()).toMatchObject({ destination: call.to_number });
    return route.fulfill({ json: { data: call, credential } });
  });
  await page.route(`**/api/v1/telephony/calls/${call.id}`, (route) => route.fulfill({ json: { data: call } }));
  await page.route(`**/api/v1/telephony/calls/${call.id}/end`, (route) => {
    call = { ...call, status: "ended", ended_at: new Date().toISOString(), can_join: false, can_end: false, active_on_this_device: false };
    return route.fulfill({ json: { data: call } });
  });
  const peer = await context.newPage();
  await instrument(peer);
  await peer.route("**/api/v1/status", (route) => route.fulfill({ json: mockServiceStatus() }));
  try {
    await page.goto("/app/calls/phone");
    await peer.goto("/");
    await peer.evaluate(async ({ url, credential: peerToken }) => {
      const sdkUrl = "/app/node_modules/.vite/deps/livekit-client.js";
      const sdk = await import(sdkUrl) as typeof LiveKit;
      const room = new sdk.Room();
      (window as typeof window & { __phonePeer?: Room }).__phonePeer = room;
      await room.connect(url, peerToken);
      await room.localParticipant.setMicrophoneEnabled(true);
    }, { url: serverUrl, credential: token(roomName, "synthetic-carrier-peer") });
    await page.getByLabel("Phone number").fill(call.to_number);
    await page.getByRole("button", { name: "Call number" }).click();
    await expect(page.getByText("Ringing · Audio connected")).toBeVisible({ timeout: 20_000 });
    // Browser connection alone must not claim the external call was answered.
    expect(call.status).toBe("ringing");
    await expect.poll(() => page.locator("audio").count(), { timeout: 20_000 }).toBeGreaterThan(0);
    await Promise.all([expectInboundMedia(page), expectInboundMedia(peer)]);
    await page.getByRole("button", { name: "End call", exact: true }).click();
    await expect(page.getByText("Ended", { exact: true })).toBeVisible();
    await expect.poll(() => page.evaluate(() => {
      const tracks = (window as typeof window & { __phoneTracks?: MediaStreamTrack[] }).__phoneTracks ?? [];
      return tracks.length >= 2 && tracks.every((track) => track.readyState === "ended");
    })).toBe(true);
    await expect(page.locator("audio")).toHaveCount(0);
  } finally {
    await peer.evaluate(() => (window as typeof window & { __phonePeer?: Room }).__phonePeer?.disconnect()).catch(() => undefined);
    await peer.close();
  }
});

function token(room: string, identity: string): string {
  const key = process.env.K_COMMS_PHONE_MEDIA_KEY ?? "kcomms-local-api-key";
  const secret = process.env.K_COMMS_PHONE_MEDIA_SECRET ?? "kcomms-local-api-secret-not-for-prod";
  const now = Math.floor(Date.now() / 1_000);
  const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify({ iss: key, sub: identity, nbf: now - 5, exp: now + 600, video: { roomJoin: true, room, canPublish: true, canSubscribe: true, canPublishData: false, canPublishSources: ["microphone"] } })).toString("base64url");
  const signingInput = `${header}.${payload}`;
  return `${signingInput}.${createHmac("sha256", secret).update(signingInput).digest("base64url")}`;
}

async function instrument(page: Page) {
  await page.addInitScript(() => {
    const captured = window as typeof window & { __phoneTracks?: MediaStreamTrack[]; __phoneConnections?: RTCPeerConnection[] };
    captured.__phoneTracks = [];
    captured.__phoneConnections = [];
    const original = window.RTCPeerConnection;
    window.RTCPeerConnection = class extends original {
      constructor(...args: ConstructorParameters<typeof RTCPeerConnection>) { super(...args); captured.__phoneConnections?.push(this); }
    };
    const getMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    navigator.mediaDevices.getUserMedia = async (constraints) => {
      const stream = await getMedia(constraints);
      captured.__phoneTracks?.push(...stream.getTracks());
      return stream;
    };
  });
}

async function expectInboundMedia(page: Page) {
  await expect.poll(() => page.evaluate(async () => {
    const connections = (window as typeof window & { __phoneConnections?: RTCPeerConnection[] }).__phoneConnections ?? [];
    let bytes = 0;
    for (const connection of connections) {
      const stats = await connection.getStats();
      stats.forEach((report) => { if (report.type === "inbound-rtp" && report.kind === "audio") bytes += Number(report.bytesReceived ?? 0); });
    }
    return bytes;
  }), { timeout: 20_000 }).toBeGreaterThan(0);
}
