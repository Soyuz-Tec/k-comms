export type MeetingStatus = "scheduled" | "cancelled";

export interface MeetingRecurrence {
  frequency: "none" | "daily" | "weekly";
  interval: number;
  count: number;
}

export interface MeetingHostPolicy {
  allow_guests: boolean;
  join_before_host: boolean;
}

export interface MeetingOccurrence {
  id: string;
  starts_at: string;
  ends_at: string;
  status: MeetingStatus;
  call_id?: string | null;
}

export interface Meeting {
  id: string;
  conversation_id: string;
  host_user_id: string;
  title: string;
  timezone: string;
  local_start: string;
  duration_minutes: number;
  recurrence: MeetingRecurrence;
  reminder_minutes: number;
  host_policy: MeetingHostPolicy;
  version: number;
  status: MeetingStatus;
  occurrences: MeetingOccurrence[];
  can_manage: boolean;
}

export interface MeetingInput {
  title: string;
  timezone: string;
  local_start: string;
  duration_minutes: number;
  recurrence: MeetingRecurrence;
  reminder_minutes: number;
  host_policy: MeetingHostPolicy;
}

export interface UpdateMeetingInput extends MeetingInput {
  expected_version: number;
}

export interface MeetingsQuery {
  from: string;
  to: string;
}
