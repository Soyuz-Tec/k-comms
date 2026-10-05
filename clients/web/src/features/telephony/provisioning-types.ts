import type { PhoneNumberInput } from "./types";

export interface PhoneProvisioningCommand {
  id: string;
  request_id: string;
  status: "inspecting" | "verified" | "applying" | "unknown" | "applied" | "failed" | "reconciling";
  version: number;
  assignment_version: number;
  desired: Omit<PhoneNumberInput, "reason" | "version">;
  dispatch_ready: boolean;
  dispatch_rule_id: string | null;
  observed_at: string | null;
  failure_reason: string | null;
  effect_in_progress: boolean;
}
export interface PhoneProvisioningState {
  provider: { enabled: boolean; ready: boolean; reason: string | null; number_purchase: false; trunk_credentials_edit: false };
  assignment_version: number;
  commands: PhoneProvisioningCommand[];
}
export interface PhoneProvisioningInput extends Omit<PhoneNumberInput, "version"> {
  assignment_version: number;
  idempotency_key: string;
}
export interface PhoneProvisioningAction { version: number; reason: string }
