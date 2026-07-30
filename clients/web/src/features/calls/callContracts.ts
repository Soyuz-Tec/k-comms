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
  audioCall?: (conversationId: string) => Promise<Call | null>;
  startAudioCall?: (conversationId: string) => Promise<CallSessionResponse>;
  joinAudioCall?: (
    conversationId: string,
    callId: string
  ) => Promise<CallSessionResponse>;
  endAudioCall?: (conversationId: string, callId: string) => Promise<Call>;
}
