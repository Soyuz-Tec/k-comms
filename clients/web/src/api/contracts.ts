import type { ServiceAccountScope } from "../types";

export interface ApiRequestOptions extends RequestInit {
  retryAuthentication?: boolean;
  skipAuthentication?: boolean;
}

export interface BootstrapInput {
  tenant_name: string;
  tenant_slug: string;
  display_name: string;
  email: string;
  password: string;
  device_name: string;
  device_platform: "web";
}

export interface LoginInput {
  tenant_slug: string;
  email: string;
  password: string;
  device: { name: string; platform: "web" };
}

export interface CreateConversationInput {
  title?: string;
  kind: "direct" | "group" | "channel";
  visibility: "private" | "tenant";
  member_ids: string[];
}

export interface SendMessageInput {
  client_message_id: string;
  body: string;
  attachment_ids: string[];
  reply_to_message_id?: string | null;
  mentioned_user_ids?: string[];
}

export interface UpdateTenantInput {
  name: string;
  allow_audio_calls: boolean;
  allow_video_calls: boolean;
  allow_public_channels: boolean;
  message_edit_window_seconds: number;
  max_attachment_bytes: number;
  default_retention_days: number;
  max_active_users: number;
  max_active_conversations: number;
  max_conversation_members: number;
  version: number;
}

export interface CreateServiceAccountInput {
  name: string;
  scopes: ServiceAccountScope[];
  expires_at: string;
  reason: string;
}

export interface AuditExportInput {
  q?: string;
  action?: string;
  resource_type?: string;
  actor_user_id?: string;
  request_id?: string;
  after?: string;
  before?: string;
  limit?: number;
}

export interface AuditExportFile {
  blob: Blob;
  filename: string;
  count: number;
  truncated: boolean;
}

export type ApiRequest = <T = void>(
  path: string,
  options?: ApiRequestOptions
) => Promise<T>;

export type ApiDownload = (
  path: string,
  options?: ApiRequestOptions
) => Promise<AuditExportFile>;
