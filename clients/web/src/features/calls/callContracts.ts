import type {
  Call,
  CallMediaKind,
  CallSessionResponse
} from "../../types";

export type CallPhase =
  | "loading"
  | "idle"
  | "prejoin"
  | "joining"
  | "connected"
  | "reconnecting"
  | "leaving"
  | "ended"
  | "error";

export interface CallPanelSessionState {
  conversationId: string;
  callId: string | null;
  phase: CallPhase;
  mediaKind: CallMediaKind;
  joined: boolean;
  microphoneEnabled: boolean;
  cameraEnabled: boolean;
  screenShareEnabled: boolean;
  canEnd: boolean;
  accessRevoked: boolean;
}

export interface CallApi {
  socketTicket?: () => Promise<{ ticket: string; expires_in: number }>;
  call?: (conversationId: string) => Promise<Call | null>;
  startCall?: (
    conversationId: string,
    mediaKind: CallMediaKind
  ) => Promise<CallSessionResponse>;
  joinCall?: (
    conversationId: string,
    callId: string
  ) => Promise<CallSessionResponse>;
  endCall?: (conversationId: string, callId: string) => Promise<Call>;
  muteCallParticipant?: (conversationId: string, callId: string, providerIdentity: string, trackSid: string) => Promise<void>;
  removeCallParticipant?: (conversationId: string, callId: string, providerIdentity: string) => Promise<void>;
  audioCall?: (conversationId: string) => Promise<Call | null>;
  startAudioCall?: (conversationId: string) => Promise<CallSessionResponse>;
  joinAudioCall?: (
    conversationId: string,
    callId: string
  ) => Promise<CallSessionResponse>;
  endAudioCall?: (conversationId: string, callId: string) => Promise<Call>;
}
