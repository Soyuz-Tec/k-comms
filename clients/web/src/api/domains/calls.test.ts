import { expect, it, vi } from "vitest";
import type { ApiRequest } from "../contracts";
import { createCallsApi } from "./calls";

it("sends complete-history entity and time filters together with the page cursor", async () => {
  const request = vi.fn().mockResolvedValue({ data: [], page: { has_more: false, next_cursor: null } });
  await createCallsApi(request as ApiRequest).calls({ scope: "recent", conversation_id: "room-1", started_by_user_id: "user-2", after: "2026-10-01T00:00:00+05:30", before: "2026-10-07T00:00:00+05:30", cursor: "opaque/cursor", limit: 25 });
  const url = new URL(request.mock.calls[0]![0], "https://workspace.test");
  expect(Object.fromEntries(url.searchParams)).toEqual({ scope: "recent", limit: "25", conversation_id: "room-1", started_by_user_id: "user-2", after: "2026-10-01T00:00:00+05:30", before: "2026-10-07T00:00:00+05:30", cursor: "opaque/cursor" });
});
