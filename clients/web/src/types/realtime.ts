import type { DataResponse } from "./common";
import type { Attachment, ConversationMembership, UploadDescriptor } from "./messaging";

export interface MembershipEvent {
  user_id: string;
  action: "added" | "removed" | "role_changed";
  role?: ConversationMembership["role"];
}

export interface ConversationActivityEvent {
  conversation_id: string;
  latest_sequence: number;
  event_type: string;
}

export interface ConversationMembershipEvent {
  conversation_id: string;
  action: "added" | "removed";
}

export interface NotificationAvailableEvent {
  notification_id: string;
  event_type: string;
  conversation_id?: string | null;
  message_id?: string | null;
  unread_count: number;
}

export interface AttachmentThumbnailIntent {
  content_type: string;
  byte_size: number;
  checksum_sha256: string;
}

export interface AttachmentIntentResponse extends DataResponse<Attachment> {
  upload: UploadDescriptor;
  /** Absent when no thumbnail was declared, or when one could not be authorized. */
  thumbnail_upload?: UploadDescriptor;
}

export interface AttachmentDownloadResponse extends DataResponse<Attachment> {
  download?: UploadDescriptor;
  /** Absent until the parent attachment is downloadable and a variant is verified. */
  thumbnail_download?: UploadDescriptor;
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
