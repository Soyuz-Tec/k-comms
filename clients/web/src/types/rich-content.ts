import type { Message, WhiteboardElementData } from "../types";
import type { UploadDescriptor } from "./messaging";

export interface BoardSummary { id: string; conversation_id: string; title: string; sequence: number; library_version: number; updated_at: string; }
export interface BoardVersion { id: string; label: string; through_sequence: number; actor_user_id: string; inserted_at: string; }
export interface BoardAsset { id: string; attachment_id: string; source_message_id: string; content_type: string; byte_size: number; }
export interface BoardExport { type: "excalidraw"; version: 2; source: "K-Comms"; title: string; library_version: number; through_sequence: number; elements: WhiteboardElementData[]; assets: BoardAsset[]; files: Record<string, never>; }
export interface SynchronizedDraft { conversation_id: string; thread_key: string; body: string; version: number; expires_at: string | null; }
export type UnifiedResultKind = "message" | "file" | "whiteboard" | "meeting" | "recording" | "transcript";
export interface UnifiedResult { id: string; kind: UnifiedResultKind; title: string; excerpt: string; conversation_id: string; occurred_at: string; score: number; path: string; }
export interface UnifiedSearchPage { data: UnifiedResult[]; facets: Partial<Record<UnifiedResultKind, number>>; page: { has_more: boolean; next_cursor: string | null; source_limits: Record<string, boolean>; ranking_scope: "authorized_source_candidates"; meeting_window_days: number; }; }
export interface BoardAssetDownload { data: { id: string; content_type: string; byte_size: number }; download: UploadDescriptor; }
export interface SavedItemsPage { data: Message[]; page: { truncated: boolean; has_more?: boolean; next_cursor?: string | null }; }
