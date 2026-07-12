export interface Tenant {
  id: string;
  name: string;
  slug: string;
  status: string;
}

export interface User {
  id: string;
  tenant_id: string;
  display_name: string;
  email: string;
  role: string;
  status: string;
}

export interface Device {
  id: string;
  user_id: string;
  name: string;
  platform: string;
  last_seen_at?: string | null;
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

export interface Conversation {
  id: string;
  tenant_id: string;
  kind: "direct" | "group" | "channel";
  title: string | null;
  visibility: "private" | "tenant";
  latest_sequence: number;
  membership_role?: string;
  last_read_sequence?: number;
  unread_count?: number;
  inserted_at: string;
  updated_at: string;
}

export interface Reaction {
  id?: string;
  user_id: string;
  emoji: string;
}

export interface Attachment {
  id: string;
  message_id?: string | null;
  file_name: string;
  content_type: string;
  byte_size: number;
  checksum_sha256?: string | null;
  status: "pending" | "ready" | "quarantined" | "deleted";
  uploaded_at?: string | null;
}

export interface Message {
  id: string;
  tenant_id: string;
  conversation_id: string;
  sender_user_id: string;
  sender_device_id: string;
  reply_to_message_id?: string | null;
  client_message_id: string;
  conversation_sequence: number;
  body: string | null;
  metadata: Record<string, unknown>;
  status: "active" | "deleted" | "moderated";
  edited_at?: string | null;
  deleted_at?: string | null;
  inserted_at: string;
  attachments: Attachment[];
  reactions: Reaction[];
}

export interface MeResponse {
  tenant: Tenant;
  user: User;
  device: Device;
}

export interface ListResponse<T> {
  data: T[];
}

export interface DataResponse<T> {
  data: T;
}

export interface UploadDescriptor {
  url?: string;
  upload_url?: string;
  href?: string;
  method?: string;
  headers?: Record<string, string>;
  fields?: Record<string, string>;
  expires_in?: number;
}

export interface MessagePage {
  data: Message[];
  page: {
    has_more: boolean;
    next_after_sequence: number | null;
    reset_required: boolean;
  };
}

export interface AttachmentIntentResponse extends DataResponse<Attachment> {
  upload: UploadDescriptor;
}

export interface AttachmentDownloadResponse extends DataResponse<Attachment> {
  download: UploadDescriptor;
}

export interface ReadCursorEvent {
  user_id: string;
  sequence: number;
}

export interface ReactionEvent {
  message_id: string;
  emoji: string;
  user_id: string;
}

export type ConnectionStatus = "connecting" | "live" | "reconnecting" | "offline";
