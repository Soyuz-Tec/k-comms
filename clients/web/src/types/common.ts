export interface ListResponse<T> {
  data: T[];
}

export interface DataResponse<T> {
  data: T;
}

export interface ServiceStatus {
  service: string;
  version: string;
  status: string;
  node?: string;
  capabilities?: {
    administration: boolean;
    audio_calls?: boolean;
    video_calls?: boolean;
    whiteboards?: boolean;
    attachment_scanning: boolean;
    bootstrap: boolean;
    guest_links: boolean;
    immersive_mode?: boolean;
    instant_rooms: boolean;
    notifications: boolean;
    push_notifications?: boolean;
    realtime: boolean;
    secure_account_actions: boolean;
    secure_media_actions: boolean;
    webhooks: boolean;
  };
}

export interface HealthStatus {
  status: "ok" | "ready" | "not_ready" | string;
}

export type ConnectionStatus = "connecting" | "live" | "reconnecting" | "offline";
