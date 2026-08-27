import type { Conversation } from "./messaging";

export interface Tenant {
  id: string;
  name: string;
  slug: string;
  status: string;
}

export type UserRole =
  | "member"
  | "moderator"
  | "admin"
  | "compliance_admin"
  | "security_admin"
  | "owner";

export type PlatformRole = "platform_operator" | "support_operator" | "security_operator";

export interface User {
  id: string;
  tenant_id: string;
  display_name: string;
  email?: string | null;
  account_type?: "human" | "service" | "guest";
  role: UserRole;
  platform_role?: PlatformRole | null;
  platform_role_expires_at?: string | null;
  status: string;
  version?: number;
}

export interface DirectoryPerson {
  id: string;
  display_name: string;
}

export interface RetainedSenderLabel {
  id: string;
  display_name: string;
  redacted: boolean;
}

export interface DirectoryPeoplePage {
  data: DirectoryPerson[];
  page: {
    next_cursor: string | null;
  };
}

export interface Device {
  id: string;
  user_id: string;
  name: string;
  platform: string;
  last_seen_at?: string | null;
  revoked_at?: string | null;
}

export interface Session {
  access_token: string;
  refresh_token: string;
  token_type: string;
  expires_in: number;
  received_at?: number;
  tenant: Tenant;
  user: User;
  device: Device;
}

export interface GuestLink {
  id: string;
  conversation_id: string;
  expires_at: string;
  max_uses: number;
  use_count: number;
  conversion_enabled?: boolean;
  email_hint?: string | null;
  status: "active" | "expired" | "revoked" | "exhausted";
  revoked_at?: string | null;
  version?: number;
  share_url?: string;
}

export interface GuestCapabilities {
  allow_audio_calls: boolean;
  allow_video_calls: boolean;
  /**
   * Missing during a rolling upgrade is treated as disabled by the client.
   * Account conversion is available only on a host-preauthorized, single-use
   * link and still requires the separately delivered one-time code.
   */
  conversion_enabled?: boolean;
  /**
   * Instant-room guests can upgrade the identity already in the room without
   * a host-issued verifier. This is intentionally separate from the stricter
   * pre-authorized conversion used by ordinary guest invitations.
   */
  self_service_conversion?: boolean;
  /** Masked display hint only; the guest must enter the full authorized email. */
  email_hint?: string | null;
}

export interface GuestLinkPreview {
  room_title: string;
  expires_at: string;
  conversion_enabled: boolean;
  email_hint: string | null;
}

export interface GuestSession extends Session {
  conversation: Conversation;
  capabilities: GuestCapabilities;
  admission?: {
    guest_link_id: string;
    expires_at: string;
  };
  instant_room?: InstantRoom;
  /** The exact public URL returned by the server. Never reconstructed client-side. */
  share_url?: string;
}

export type InstantRoomOwnerKind = "guest" | "registered";

export type InstantRoomStatus = "active" | "idle" | "expired" | "revoked";

export interface InstantRoom {
  id: string;
  conversation_id: string;
  owner_user_id: string;
  status: InstantRoomStatus;
  owner_kind: InstantRoomOwnerKind;
  participant_limit: number;
  idle_since: string | null;
  expires_at: string | null;
  inserted_at: string;
  updated_at: string;
}

export interface InstantRoomPreview {
  room_title: string;
  status: InstantRoomStatus;
  expires_at: string | null;
  participant_limit: number;
}

export interface InstantRoomResult {
  room: InstantRoom;
  conversation: Conversation;
  /** The exact public URL returned by the server. */
  share_url?: string;
  /** Present only when an anonymous visitor was admitted as the room creator. */
  guest_session?: GuestSession;
}

export interface SocketHandoff {
  ticket: string;
  expires_in: number;
}

export interface GuestAccountConversionResult {
  session: Session;
  conversation: Conversation;
  socket_handoff?: SocketHandoff;
}

export interface MeResponse {
  tenant: Tenant;
  user: User;
  device: Device;
  capabilities: UserCapabilities;
}

export interface UserCapabilities {
  allow_audio_calls: boolean;
  allow_video_calls: boolean;
  /**
   * Optional because a server that predates the immersive increment omits it,
   * and an absent switch must read as "not eligible" rather than as "true".
   */
  allow_immersive_mode?: boolean;
  allow_public_channels: boolean;
  message_edit_window_seconds: number;
  max_attachment_bytes: number;
}
