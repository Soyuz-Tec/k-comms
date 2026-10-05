import type { Session } from "./identity";

export interface MfaChallenge {
  mfa_required: true;
  challenge_token: string;
  expires_in: number;
}
export type LoginResult = Session | MfaChallenge;
export interface IdentitySecurity {
  mfa_enabled: boolean;
  authentication_method?: "password" | "oidc" | "break_glass";
  recovery_codes_remaining: number;
}
export interface MfaEnrollment {
  secret: string;
  provisioning_uri: string;
}
export interface RecoveryCodes { recovery_codes: string[] }
export interface Availability {
  status: "available" | "away" | "busy" | "dnd" | "offline";
  presence_state: "available" | "away" | "busy" | "dnd" | "offline";
  presence_expires_at: string | null;
  dnd_until: string | null;
  dnd_schedule: { days?: number[]; start?: string; end?: string };
  dnd_active: boolean;
  retry_at: string | null;
  timezone: string;
}
export type UpdateAvailability = Pick<Availability, "presence_state" | "presence_expires_at" | "dnd_until" | "dnd_schedule">;
