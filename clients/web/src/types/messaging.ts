import type { RetainedSenderLabel, User } from "./identity";

export interface DirectConversationResponse {
  data: Conversation;
  created: boolean;
}

export interface Conversation {
  id: string;
  tenant_id: string;
  kind: "direct" | "group" | "channel";
  title: string | null;
  counterpart_user_id: string | null;
  counterpart_display_name: string | null;
  visibility: "private" | "tenant";
  latest_sequence: number;
  membership_role?: string;
  last_read_sequence?: number;
  unread_count?: number;
  archived_at?: string | null;
  version?: number;
  inserted_at: string;
  updated_at: string;
}

export interface ConversationMembership {
  id: string;
  role: "member" | "moderator" | "owner";
  joined_at: string;
  last_read_sequence: number;
  version?: number;
  user: User;
}

export interface MembershipSummary {
  id: string;
  role: "member" | "moderator" | "owner";
  joined_at: string;
  left_at: string | null;
  last_read_sequence: number;
  version: number;
}

export interface PublicChannel extends Conversation {
  joined: boolean;
  member_count: number;
  membership: MembershipSummary | null;
}

export interface PublicChannelDiscoveryPage {
  data: PublicChannel[];
  page: {
    limit: number;
    has_more: boolean;
    next_cursor: string | null;
  };
}

export interface PublicChannelMembershipResponse {
  data: {
    conversation: Conversation;
    membership: MembershipSummary;
  };
  replayed: boolean;
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
  status: "pending" | "uploaded" | "ready" | "quarantined" | "scan_failed" | "deleted";
  scan_status?: "pending" | "scanning" | "clean" | "blocked" | "failed" | null;
  scan_verdict?: string | null;
  scan_provider?: string | null;
  scan_attempts?: number;
  scan_error_code?: string | null;
  scanned_at?: string | null;
  quarantined_at?: string | null;
  uploaded_at?: string | null;
  /** Kinds of verified variants. Empty or absent means no preview exists. */
  variant_kinds?: string[];
}

export type FileSafetyState =
  | "available"
  | "processing"
  | "blocked"
  | "failed"
  | "unavailable";

export type FilesScope = "recent" | "shared_by_me";

export interface FileSummary {
  id: string;
  conversation_id: string;
  message_id: string;
  conversation_sequence: number;
  owner_user_id: string;
  file_name: string;
  content_type: string;
  byte_size: number;
  status: Exclude<Attachment["status"], "deleted">;
  scan_status: NonNullable<Attachment["scan_status"]>;
  safety_state: FileSafetyState;
  downloadable: boolean;
  uploaded_at: string | null;
  shared_at: string;
  inserted_at: string;
  updated_at: string;
}

export interface FilesPageResponse {
  data: FileSummary[];
  page: {
    limit: number;
    has_more: boolean;
    next_cursor: string | null;
  };
}

export interface FilesQueryOptions {
  scope?: FilesScope;
  conversation_id?: string;
  limit?: number;
  cursor?: string | null;
}

export interface Message {
  id: string;
  tenant_id: string;
  conversation_id: string;
  sender_user_id: string;
  sender_device_id: string;
  reply_to_message_id?: string | null;
  thread_root_message_id?: string | null;
  thread_reply_count?: number;
  mentioned_user_ids?: string[];
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

export interface MessageThread {
  data: {
    root: Message;
    replies: Message[];
    reply_count: number;
  };
  included?: {
    sender_labels: RetainedSenderLabel[];
  };
  page: {
    has_more: boolean;
    next_before_sequence: number | null;
  };
}

export interface UploadDescriptor {
  url?: string;
  upload_url?: string;
  href?: string;
  method?: string;
  headers?: Record<string, string>;
  fields?: Record<string, string>;
  expires_in?: number;
  expires_at?: string;
  approved_origin?: string;
}

export interface MessagePage {
  data: Message[];
  included?: {
    sender_labels: RetainedSenderLabel[];
  };
  page: {
    has_more: boolean;
    next_after_sequence: number | null;
    reset_required: boolean;
  };
}

export interface MessageSearchOptions {
  conversation_id?: string;
  sender_user_id?: string;
  after?: string;
  before?: string;
  cursor?: string | null;
  limit?: number;
}

export interface MessageSearchPage {
  data: Message[];
  included?: {
    sender_labels: RetainedSenderLabel[];
  };
  page: {
    limit: number;
    has_more: boolean;
    next_cursor: string | null;
  };
}
