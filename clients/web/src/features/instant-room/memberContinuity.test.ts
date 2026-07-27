import { beforeEach, describe, expect, it } from "vitest";
import type {
  Conversation,
  InstantRoom,
  Session
} from "../../types";
import {
  capturedInstantRoomShareUrl,
  clearMemberInstantRoomContinuity,
  loadMemberInstantRoomContinuity,
  storeMemberInstantRoomContinuity
} from "./memberContinuity";

const session = {
  tenant: { id: "tenant-1" },
  user: { id: "member-1" }
} as Session;
const conversation = {
  id: "conversation-1",
  tenant_id: "tenant-1"
} as Conversation;
const room: InstantRoom = {
  id: "room-1",
  conversation_id: conversation.id,
  owner_user_id: session.user.id,
  owner_kind: "registered",
  status: "active",
  participant_limit: 25,
  idle_since: null,
  expires_at: null,
  inserted_at: "2026-07-24T12:00:00Z",
  updated_at: "2026-07-24T12:00:00Z"
};
const token = "A".repeat(43);
const shareUrl = `https://comms.example.test/join#guest=${token}`;

describe("member instant-room continuity", () => {
  beforeEach(() => {
    window.sessionStorage.clear();
    window.localStorage.clear();
  });

  it("stores only bounded member room metadata in tab storage", () => {
    expect(storeMemberInstantRoomContinuity(session, {
      room,
      conversation,
      share_url: shareUrl
    })).toBe(true);

    const serialized =
      window.sessionStorage.getItem("k-comms.member-instant-room.v1") || "";
    expect(serialized).toContain(room.id);
    expect(serialized).toContain(shareUrl);
    expect(serialized).not.toContain("access_token");
    expect(serialized).not.toContain("refresh_token");
    expect(window.localStorage.length).toBe(0);
    expect(loadMemberInstantRoomContinuity(session)).toEqual({
      room,
      conversation,
      share_url: shareUrl
    });
  });

  it("clears records on account mismatch or terminal room state", () => {
    storeMemberInstantRoomContinuity(session, {
      room,
      conversation,
      share_url: shareUrl
    });
    expect(loadMemberInstantRoomContinuity({
      ...session,
      user: { ...session.user, id: "other-member" }
    })).toBeNull();
    expect(
      window.sessionStorage.getItem("k-comms.member-instant-room.v1")
    ).toBeNull();

    storeMemberInstantRoomContinuity(session, {
      room: { ...room, status: "expired" },
      conversation,
      share_url: shareUrl
    });
    expect(loadMemberInstantRoomContinuity(session)).toBeNull();
  });

  it("captures only the exact fragment bearer URL and clears explicitly", () => {
    const href = `http://127.0.0.1:4178/join#guest=${token}`;
    expect(capturedInstantRoomShareUrl(token, href)).toBe(href);
    expect(
      capturedInstantRoomShareUrl(token, `${href}?token=${token}`)
    ).toBeNull();

    storeMemberInstantRoomContinuity(session, {
      room,
      conversation,
      share_url: shareUrl
    });
    clearMemberInstantRoomContinuity();
    expect(loadMemberInstantRoomContinuity(session)).toBeNull();
  });
});
