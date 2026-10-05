export type IvrTarget =
  | { kind: "hangup" }
  | { kind: "route"; route_id: string }
  | { kind: "voicemail"; mailbox_id: string }
  | { kind: "destination"; destination: string };

export interface IvrMenu {
  id: string;
  name: string;
  prompt_media: string;
  choices: Record<string, IvrTarget>;
  fallback: IvrTarget;
  digit_timeout_seconds: number;
  max_retries: number;
  enabled: boolean;
  version: number;
}

export type IvrMenuInput = Omit<IvrMenu, "id"> & { reason: string };
export interface IvrConfiguration {
  menu: IvrMenu | null;
  available: boolean;
  max_active_callers: number;
  approved_prompts: string[];
}

export type AgentQueueStatus = "ready" | "away" | "wrap_up";
export interface AgentQueueState {
  state: AgentQueueStatus;
  expires_at: string | null;
  version: number;
  explicit: boolean;
  online_presence_observed: false;
}
export interface AgentQueueStateInput {
  state: AgentQueueStatus;
  duration_seconds: number;
  version: number;
}

export interface QueueSnapshot {
  routes: {
    id: string;
    name: string;
    mode: "shared_line" | "queue";
    enabled: boolean;
    configured_members: number;
    max_waiting: number;
    max_wait_seconds: number;
    waiting_calls: number;
    offered_calls: number;
    answered_calls: number;
    oldest_observed_wait_seconds: number | null;
  }[];
  observed_at: string;
  coverage: "current_retained_calls";
  online_presence_observed: false;
  historical_service_level_available: false;
  oldest_wait_basis: "call_started_at";
}

export function validIvrTarget(target: IvrTarget): boolean {
  switch (target.kind) {
    case "hangup": return true;
    case "route": return target.route_id.length > 0;
    case "voicemail": return target.mailbox_id.length > 0;
    case "destination": return /^\+[1-9]\d{7,14}$/.test(target.destination);
  }
}
