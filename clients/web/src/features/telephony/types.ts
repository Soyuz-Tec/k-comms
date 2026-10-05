import type { CallCredential } from "../../types";

export type PhoneCallStatus = "ringing" | "answered" | "declined" | "busy" | "no_answer" | "cancelled" | "failed" | "ended";

export interface PhoneNumberAssignment {
  id: string;
  phone_number: string;
  extension: string;
  user_id: string;
  inbound_trunk_id?: string;
  outbound_trunk_id?: string;
  version?: number;
}

export interface PhoneConfiguration {
  enabled: boolean;
  configured: boolean;
  /** Optional while older servers roll forward; configured remains the compatibility gate. */
  provider_ready?: boolean;
  line_assigned?: boolean;
  provider: "livekit_sip";
  number: PhoneNumberAssignment | null;
  can_manage: boolean;
}

export interface PhoneCall {
  id: string;
  direction: "inbound" | "outbound";
  status: PhoneCallStatus;
  from_number: string;
  to_number: string;
  extension: string;
  started_at: string;
  answered_at: string | null;
  ended_at: string | null;
  connected_seconds: number;
  can_answer: boolean;
  can_join: boolean;
  can_end: boolean;
  active_on_this_device: boolean;
  end_reason?: string | null;
  control_state?: "connected" | "held" | "consulting" | "transferred" | "voicemail";
}

export interface PhoneSession {
  data: PhoneCall;
  credential: CallCredential;
}

export type PhoneControlAction = "dtmf" | "hold" | "resume" | "blind_transfer" | "consult_transfer" | "complete_transfer" | "cancel_transfer" | "voicemail";
export type PhoneCapabilityName = PhoneControlAction | "queues" | "shared_lines";
export interface PhoneCapability { supported: boolean; configured?: boolean; qualified?: boolean; reason: string | null; transport?: string; assurance?: string }
export type PhoneCapabilities = Partial<Record<PhoneCapabilityName, PhoneCapability>>;
export interface PhoneControlInput { action: PhoneControlAction; idempotency_key: string; digit?: string; destination?: string }
export interface PhoneControlReceipt {
  id: string; call_id: string; action: PhoneControlAction; status: "pending" | "dispatching" | "submitted" | "failed" | "unknown";
  dispatch: boolean; created_at: string; expires_at: string; completed_at: string | null; failure_reason: string | null;
}

export interface PhoneRoute {
  id: string; name: string; mode: "queue" | "shared_line"; policy: "round_robin" | "simultaneous";
  member_ids: string[]; max_waiting: number; max_wait_seconds: number; enabled: boolean; version: number;
}
export type PhoneRouteInput = Omit<PhoneRoute, "id" | "version"> & { version?: number; reason: string };

export interface PhoneCallsPage {
  data: PhoneCall[];
  page: { limit: number; has_more: boolean; next_cursor: string | null };
}

export interface PhoneNumberInput {
  version?: number;
  phone_number: string;
  extension: string;
  user_id: string;
  inbound_trunk_id: string;
  outbound_trunk_id: string;
  reason: string;
}

export function phoneReadiness(configuration: PhoneConfiguration | null) {
  const enabled = Boolean(configuration?.enabled);
  const providerReady = configuration?.provider_ready ?? Boolean(configuration?.configured);
  const lineAssigned = configuration?.line_assigned ?? Boolean(configuration?.number);
  const canCall = enabled && Boolean(configuration?.configured) && providerReady && lineAssigned && Boolean(configuration?.number);
  const state = !configuration ? "unknown" : !enabled ? "disabled" : !providerReady ? "provider_setup" : !lineAssigned || !configuration.number ? "unassigned" : "ready";
  return { enabled, providerReady, lineAssigned, canCall, state } as const;
}

export function phoneSetupAdvice(configuration: PhoneConfiguration | null) {
  const { state } = phoneReadiness(configuration);
  const admin = configuration?.can_manage;
  switch (state) {
    case "disabled": return { title: "Phone service is off", next: admin ? "Ask the service operator to complete provider and carrier checks before enabling phone calls. You can review the workspace line assignment below." : "Your workspace administrator can coordinate phone service setup with the service operator." };
    case "provider_setup": return { title: "Phone provider needs setup", next: admin ? "Ask the service operator to check the LiveKit SIP configuration. Saving a workspace line does not connect the provider." : "Ask your workspace administrator to check phone provider availability with the service operator." };
    case "unassigned": return { title: "No phone line assigned", next: admin ? "Assign a carrier number and extension to your account in workspace phone settings." : "Ask your workspace administrator to assign you a phone number and extension." };
    default: return { title: "Phone availability could not be checked", next: "Refresh phone availability to check whether calling is ready." };
  }
}

export function phoneNumberInputError(input: PhoneNumberInput, eligibleUserIds: string[]): string | null {
  if (!/^\+[1-9]\d{7,14}$/.test(input.phone_number)) return "Enter an international phone number with +, a country code, and 8–15 digits.";
  if (!/^\d{2,8}$/.test(input.extension)) return "Use 2–8 digits for the extension.";
  if (!eligibleUserIds.includes(input.user_id)) return "Choose an active workspace member for this line.";
  if (![input.inbound_trunk_id, input.outbound_trunk_id].every((id) => /^[A-Za-z0-9_-]{2,200}$/.test(id))) return "SIP trunk IDs must contain 2–200 letters, digits, underscores, or hyphens.";
  const reasonLength = new TextEncoder().encode(input.reason).length;
  if (reasonLength < 3 || reasonLength > 500) return "Enter a brief, descriptive reason for the audit record. Shorten it if it is too long.";
  return null;
}

export function phoneCallIsActive(call: PhoneCall): boolean {
  return call.status === "ringing" || call.status === "answered";
}

export function phoneCallLabel(call: PhoneCall): string {
  if (call.end_reason === "answer_unconfirmed") return "Answer unconfirmed";
  if (call.status === "busy" && call.direction === "inbound") return "Missed (busy)";
  if (call.status === "no_answer") return call.direction === "inbound" ? "Missed" : "No answer";
  return ({ ringing: "Ringing", answered: "Answered", declined: "Declined", busy: "Busy", cancelled: "Cancelled", failed: "Failed", ended: "Ended" })[call.status];
}

export function phoneDurationLabel(call: PhoneCall): string {
  return call.end_reason === "answer_unconfirmed" ? "Duration unconfirmed" : `${call.connected_seconds}s connected`;
}

export function otherPhoneNumber(call: PhoneCall): string {
  return call.direction === "inbound" ? call.from_number : call.to_number;
}
