export type CallMediaKind = "audio" | "video";

export interface Call {
  id: string;
  conversation_id: string;
  started_by_user_id: string;
  /** Omitted only by legacy audio broadcasts during a rolling deployment. */
  media_kind?: CallMediaKind;
  status: "active" | "ended";
  started_at: string;
  expires_at: string;
  ended_at?: string | null;
  can_end: boolean;
}

export interface CallRealtimeEvent {
  id: string;
  conversation_id: string;
  started_by_user_id: string;
  /** Omitted only by legacy audio broadcasts during a rolling deployment. */
  media_kind?: CallMediaKind;
  status: "active" | "ended";
  started_at: string;
  expires_at: string;
  ended_by_user_id?: string | null;
  ended_at?: string | null;
  end_reason?: string | null;
}

export interface CallIceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export interface CallCredential {
  server_url: string;
  participant_token: string;
  expires_in: number;
  ice_servers?: CallIceServer[];
}

export interface CallSessionResponse {
  data: Call;
  credential: CallCredential;
}

export interface CallParticipantState {
  id: string;
  user_id: string;
  status: "admitted";
  hand_raised: boolean;
  hand_raised_at: string | null;
}

export type CallsScope = "active" | "recent";

export interface CallSummary {
  id: string;
  conversation_id: string;
  started_by_user_id: string;
  ended_by_user_id: string | null;
  media_kind: CallMediaKind;
  status: "active" | "ending" | "ended";
  started_at: string;
  expires_at: string;
  ended_at: string | null;
  end_reason: string | null;
  duration_seconds: number;
  can_end: boolean;
}

export interface CallsPageResponse {
  data: CallSummary[];
  page: {
    limit: number;
    has_more: boolean;
    next_cursor: string | null;
  };
}

export interface CallsQueryOptions {
  scope?: CallsScope;
  media_kind?: CallMediaKind;
  limit?: number;
  cursor?: string | null;
}

/** Compatibility aliases for consumers migrating from the audio-only surface. */
export type AudioCall = Call;

export type AudioCallRealtimeEvent = CallRealtimeEvent;

export type AudioCallCredential = CallCredential;

export type AudioCallSessionResponse = CallSessionResponse;
