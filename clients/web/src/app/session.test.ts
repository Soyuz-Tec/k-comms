import { beforeEach, describe, expect, it } from "vitest";
import { loadStoredSession, storeSession } from "../api";
import type { Session } from "../types";
import { loadMemberSessionForOrigin } from "./session";

const session: Session = {
  access_token: "member-access",
  refresh_token: "member-refresh",
  token_type: "Bearer",
  expires_in: 900,
  tenant: { id: "tenant-1", name: "Acme", slug: "acme", status: "active" },
  user: {
    id: "user-1",
    tenant_id: "tenant-1",
    display_name: "Taylor",
    email: "taylor@example.test",
    account_type: "human",
    role: "member",
    status: "active"
  },
  device: {
    id: "device-1",
    user_id: "user-1",
    name: "Browser",
    platform: "web",
    last_seen_at: "2026-07-25T00:00:00Z"
  }
};

describe("member session transport boundary", () => {
  beforeEach(() => window.sessionStorage.clear());

  it("restores a member session on HTTPS or a trustworthy loopback origin", () => {
    storeSession(session);
    expect(loadMemberSessionForOrigin(false)).toEqual(session);
    expect(loadStoredSession()).toEqual(session);
  });

  it("clears a retained member credential on an insecure network origin", () => {
    storeSession(session);
    expect(loadMemberSessionForOrigin(true)).toBeNull();
    expect(loadStoredSession()).toBeNull();
  });
});
