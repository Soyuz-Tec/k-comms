export interface VoicemailMessage {
  id: string;
  call_id: string;
  status: "pending" | "available" | "failed" | "deleting" | "deleted";
  duration_seconds: number | null;
  retention_expires_at: string;
  available_at: string | null;
  inserted_at: string;
  read_at: string | null;
}
export interface VoicemailPage {
  data: VoicemailMessage[];
  page: { limit: number; has_more: boolean; next_cursor: string | null };
  configured: boolean;
}
export interface VoicemailPlayback {
  url: string;
  approved_origin: string;
  development_http: boolean;
  expires_at: string;
  expires_in: number;
  content_type: "audio/wav";
}
export interface VoicemailMailbox {
  id: string;
  user_id: string;
  enabled: boolean;
  retention_days: number;
  notice_media: string;
  version: number;
}
export interface VoicemailMailboxInput {
  user_id: string;
  enabled: boolean;
  retention_days: number;
  notice_media: string;
  version?: number;
  reason: string;
}
export function approvedVoicemailPlayback(playback: VoicemailPlayback): boolean {
  try {
    const url = new URL(playback.url);
    const origin = new URL(playback.approved_origin);
    const development = playback.development_http && url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
    return playback.content_type === "audio/wav" && !url.username && !url.password && !url.hash &&
      url.origin === origin.origin && origin.pathname === "/" && !origin.search && !origin.hash &&
      (url.protocol === "https:" || development) &&
      url.searchParams.has("versionId") && !["", "null"].includes(url.searchParams.get("versionId") ?? "") &&
      Number.isFinite(Date.parse(playback.expires_at)) && Date.parse(playback.expires_at) > Date.now();
  } catch { return false; }
}
