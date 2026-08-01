import { describe, expect, it } from "vitest";
import type { Conversation } from "../types";
import { conversationTitle, dayKey, formatDayLabel } from "./format";

function conversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: "conversation-1",
    tenant_id: "tenant-1",
    kind: "channel",
    title: "General",
    counterpart_user_id: null,
    counterpart_display_name: null,
    visibility: "tenant",
    latest_sequence: 0,
    inserted_at: "2026-07-24T00:00:00Z",
    updated_at: "2026-07-24T00:00:00Z",
    ...overrides
  };
}

describe("conversationTitle", () => {
  it("uses only the server-derived counterpart label for direct conversations", () => {
    expect(
      conversationTitle(
        conversation({
          kind: "direct",
          title: "stale-client-controlled-title",
          counterpart_user_id: "user-2",
          counterpart_display_name: "  Grace Hopper  ",
          visibility: "private"
        })
      )
    ).toBe("Grace Hopper");
  });

  it("uses privacy-safe fallbacks when the projected label or room title is absent", () => {
    expect(
      conversationTitle(
        conversation({
          kind: "direct",
          title: null,
          counterpart_user_id: null,
          counterpart_display_name: null,
          visibility: "private"
        })
      )
    ).toBe("Direct message");

    expect(conversationTitle(conversation({ title: "  " }))).toBe("Untitled conversation");
  });
});

describe("message day formatting", () => {
  it("uses the reader's local calendar day instead of UTC boundaries", () => {
    const morning = new Date(2026, 6, 24, 1, 30);
    const evening = new Date(2026, 6, 24, 23, 30);

    expect(dayKey(morning.toISOString())).toBe(dayKey(evening.toISOString()));
  });

  it("labels current and previous local days and rejects invalid timestamps", () => {
    const now = new Date(2026, 6, 24, 12);
    const yesterday = new Date(2026, 6, 23, 12);

    expect(formatDayLabel(now.toISOString(), now)).toBe("Today");
    expect(formatDayLabel(yesterday.toISOString(), now)).toBe("Yesterday");
    expect(formatDayLabel("not-a-timestamp", now)).toBe("");
    expect(dayKey("not-a-timestamp")).toBe("");
  });
});
