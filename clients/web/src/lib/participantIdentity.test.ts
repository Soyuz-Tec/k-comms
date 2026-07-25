import { describe, expect, it } from "vitest";
import {
  conversationParticipantIdentifier,
  duplicateDirectConversationNames,
  duplicateParticipantNames,
  mergeRetainedSenderLabelMaps,
  participantDisambiguator,
  participantIdentifier,
  retainedSenderLabelMap,
  resolveVisibleSenderIdentity
} from "./participantIdentity";

describe("participant identity", () => {
  it("disambiguates normalized duplicate names with stable user-derived codes", () => {
    const first = { id: "user-alpha", display_name: "Åsa" };
    const second = { id: "user-beta", display_name: "A\u030Asa" };
    const duplicateNames = duplicateParticipantNames([first, second]);

    expect(participantIdentifier(first, duplicateNames)).toBe(
      `Åsa · #${participantDisambiguator(first.id)}`
    );
    expect(participantIdentifier(second, duplicateNames)).toBe(
      `A\u030Asa · #${participantDisambiguator(second.id)}`
    );
    expect(participantDisambiguator(first.id)).toMatch(/^[0-9A-Z]{5}$/);
    expect(participantDisambiguator(first.id)).not.toBe(
      participantDisambiguator(second.id)
    );
  });

  it("never lets an older sender label replace an erasure tombstone", () => {
    const deleted = retainedSenderLabelMap([
      { id: "user-1", display_name: "Deleted user", redacted: true }
    ]);

    const merged = mergeRetainedSenderLabelMaps(deleted, [
      { id: "user-1", display_name: "Alice Example", redacted: false },
      { id: "user-2", display_name: "Visible teammate", redacted: false }
    ]);

    expect(merged.get("user-1")?.display_name).toBe("Deleted user");
    expect(merged.get("user-2")?.display_name).toBe("Visible teammate");
  });

  it("makes an erasure tombstone outrank stale active and directory identities", () => {
    const staleActive = new Map([
      ["user-1", { id: "user-1", display_name: "Alice Active" }]
    ]);
    const staleDirectory = new Map([
      ["user-1", { id: "user-1", display_name: "Alice Directory" }]
    ]);
    const deleted = retainedSenderLabelMap([
      { id: "user-1", display_name: "Deleted user", redacted: true }
    ]);

    expect(
      resolveVisibleSenderIdentity(
        "user-1",
        staleActive,
        deleted,
        [staleDirectory]
      )?.display_name
    ).toBe("Deleted user");
  });

  it("does not treat repeated projections of the same user as duplicate people", () => {
    const participant = { id: "same-user", display_name: "Taylor" };
    const duplicateNames = duplicateParticipantNames([
      participant,
      { ...participant, display_name: " TAYLOR " }
    ]);

    expect(duplicateNames.size).toBe(0);
    expect(participantIdentifier(participant, duplicateNames)).toBe("Taylor");
  });

  it("normalizes duplicate-name casing independently of the browser locale", () => {
    const first = { id: "one", display_name: "Iris" };
    const second = { id: "two", display_name: "IRIS" };
    const duplicates = duplicateParticipantNames([first, second]);

    expect(participantIdentifier(first, duplicates)).toContain(
      `#${participantDisambiguator(first.id)}`
    );
    expect(participantIdentifier(second, duplicates)).toContain(
      `#${participantDisambiguator(second.id)}`
    );
  });

  it("uses the direct counterpart ID to disambiguate actionable conversations", () => {
    const base = {
      tenant_id: "tenant-1",
      kind: "direct" as const,
      title: null,
      visibility: "private" as const,
      latest_sequence: 0,
      inserted_at: "2026-07-24T00:00:00Z",
      updated_at: "2026-07-24T00:00:00Z"
    };
    const first = {
      ...base,
      id: "direct-1",
      counterpart_user_id: "user-1",
      counterpart_display_name: "Alex"
    };
    const second = {
      ...base,
      id: "direct-2",
      counterpart_user_id: "user-2",
      counterpart_display_name: "ALEX"
    };
    const duplicates = duplicateDirectConversationNames([first, second]);

    expect(conversationParticipantIdentifier(first, duplicates)).toBe(
      `Alex · #${participantDisambiguator("user-1")}`
    );
    expect(conversationParticipantIdentifier(second, duplicates)).toBe(
      `ALEX · #${participantDisambiguator("user-2")}`
    );
  });

  it("lengthens colliding short codes so duplicate-name identifiers stay unique", () => {
    const first = {
      id: "00000000-0000-4000-8000-000000005229",
      display_name: "Alex"
    };
    const second = {
      id: "00000000-0000-4000-8000-000000054784",
      display_name: "Alex"
    };
    expect(participantDisambiguator(first.id)).toBe(
      participantDisambiguator(second.id)
    );

    const duplicates = duplicateParticipantNames([first, second]);
    const firstIdentifier = participantIdentifier(first, duplicates);
    const secondIdentifier = participantIdentifier(second, duplicates);

    expect(firstIdentifier).not.toBe(secondIdentifier);
    expect(firstIdentifier).toMatch(/^Alex · #[0-9A-Z-]{6,}$/);
    expect(secondIdentifier).toMatch(/^Alex · #[0-9A-Z-]{6,}$/);
  });
});
