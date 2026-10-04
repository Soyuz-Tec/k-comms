import type { CallCredential } from "../../types";

export type PhoneCallStatus = "ringing" | "answered" | "declined" | "busy" | "no_answer" | "cancelled" | "failed" | "ended";

export interface PhoneNumberAssignment {
  id: string;
  phone_number: string;
  extension: string;
  user_id: string;
  inbound_trunk_id?: string;
  outbound_trunk_id?: string;
}

export interface PhoneConfiguration {
  enabled: boolean;
  configured: boolean;
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
}

export interface PhoneSession {
  data: PhoneCall;
  credential: CallCredential;
}

export interface PhoneCallsPage {
  data: PhoneCall[];
  page: { limit: number; has_more: boolean; next_cursor: string | null };
}

export interface PhoneNumberInput {
  phone_number: string;
  extension: string;
  user_id: string;
  inbound_trunk_id: string;
  outbound_trunk_id: string;
  reason: string;
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
