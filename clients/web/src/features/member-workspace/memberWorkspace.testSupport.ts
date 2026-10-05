import type { MemberWorkspace } from "../../types";

export function workspaceFixture(overrides: Partial<MemberWorkspace> = {}): MemberWorkspace {
  return {
    version: 1,
    contacts: [],
    groups: [],
    onboarding: { dismissed_at: null, profile_reviewed_at: null, active_devices: 1, has_teammates: true },
    limits: { contacts: 500, groups: 20, members_per_group: 50 },
    observed_at: "2026-10-05T00:00:00Z",
    ...overrides
  };
}
