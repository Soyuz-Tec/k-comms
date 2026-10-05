export interface MemberContact {
  id: string;
  display_name: string;
}

export interface PrivateContactGroup {
  id: string;
  name: string;
  member_ids: string[];
}

export interface MemberWorkspace {
  version: number;
  contacts: MemberContact[];
  groups: PrivateContactGroup[];
  onboarding: {
    dismissed_at: string | null;
    profile_reviewed_at: string | null;
    active_devices: number;
    has_teammates: boolean;
  };
  limits: { contacts: number; groups: number; members_per_group: number };
  observed_at: string;
}

export interface MemberWorkspaceInput {
  version: number;
  contact_ids: string[];
  groups: PrivateContactGroup[];
}

export type OnboardingAction = "dismiss" | "resume" | "reset";
