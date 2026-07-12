import type {
  Attachment,
  AttachmentDownloadResponse,
  AttachmentIntentResponse,
  Conversation,
  DataResponse,
  ListResponse,
  MeResponse,
  Message,
  MessagePage,
  Session,
  UploadDescriptor,
  User
} from "./types";

const sessionKey = "k-comms.session.v1";

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly meta?: unknown;

  constructor(status: number, code: string, message: string, meta?: unknown) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.meta = meta;
  }
}

export function loadStoredSession(): Session | null {
  try {
    const value = window.sessionStorage.getItem(sessionKey);
    return value ? (JSON.parse(value) as Session) : null;
  } catch {
    window.sessionStorage.removeItem(sessionKey);
    return null;
  }
}

export function storeSession(session: Session | null): void {
  if (session) {
    window.sessionStorage.setItem(sessionKey, JSON.stringify(session));
  } else {
    window.sessionStorage.removeItem(sessionKey);
  }
}

interface ErrorEnvelope {
  error?: {
    code?: string;
    detail?: string;
    meta?: unknown;
  };
}

interface RequestOptions extends RequestInit {
  retryAuthentication?: boolean;
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
  title: string;
  kind: "group" | "channel";
  visibility: "private" | "tenant";
  member_ids: string[];
}

export interface CreateUserInput {
  display_name: string;
  email: string;
  password: string;
  role: "member" | "admin";
}

export interface SendMessageInput {
  client_message_id: string;
  body: string;
  attachment_ids: string[];
  reply_to_message_id?: string | null;
}

export class ApiClient {
  private session: Session | null;
  private refreshPromise: Promise<Session | null> | null = null;

  constructor(
    private readonly baseUrl: string,
    initialSession: Session | null,
    private readonly onSession: (session: Session | null) => void
  ) {
    this.session = initialSession;
  }

  setSession(session: Session | null): void {
    this.session = session;
  }

  bootstrap(input: BootstrapInput): Promise<Session & { conversation: Conversation }> {
    return this.request<Session & { conversation: Conversation }>("/api/v1/bootstrap", {
      method: "POST",
      body: JSON.stringify(input),
      retryAuthentication: false
    }).then(withReceivedAt);
  }

  login(input: LoginInput): Promise<Session> {
    return this.request<Session>("/api/v1/sessions", {
      method: "POST",
      body: JSON.stringify(input),
      retryAuthentication: false
    }).then(withReceivedAt);
  }

  me(): Promise<MeResponse> {
    return this.request("/api/v1/me");
  }

  users(): Promise<User[]> {
    return this.request<ListResponse<User>>("/api/v1/users").then((response) => response.data);
  }

  createUser(input: CreateUserInput): Promise<User> {
    return this.request<DataResponse<User>>("/api/v1/users", {
      method: "POST",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  conversations(): Promise<Conversation[]> {
    return this.request<ListResponse<Conversation>>("/api/v1/conversations").then(
      (response) => response.data
    );
  }

  createConversation(input: CreateConversationInput): Promise<Conversation> {
    return this.request<DataResponse<Conversation>>("/api/v1/conversations", {
      method: "POST",
      body: JSON.stringify(input)
    }).then((response) => response.data);
  }

  messages(conversationId: string, afterSequence = 0, limit = 200): Promise<MessagePage> {
    const query = new URLSearchParams({
      after_sequence: String(afterSequence),
      limit: String(limit)
    });
    return this.request<MessagePage>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages?${query.toString()}`
    );
  }

  sendMessage(conversationId: string, input: SendMessageInput): Promise<Message> {
    const { client_message_id: idempotencyKey, ...body } = input;
    return this.request<DataResponse<Message>>(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages`,
      {
        method: "POST",
        headers: { "Idempotency-Key": idempotencyKey },
        body: JSON.stringify(body)
      }
    ).then((response) => response.data);
  }

  addReaction(conversationId: string, messageId: string, emoji: string): Promise<void> {
    return this.request(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(messageId)}/reactions`,
      { method: "POST", body: JSON.stringify({ emoji }) }
    );
  }

  removeReaction(conversationId: string, messageId: string, emoji: string): Promise<void> {
    return this.request(
      `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(messageId)}/reactions/${encodeURIComponent(emoji)}`,
      { method: "DELETE" }
    );
  }

  markRead(conversationId: string, sequence: number): Promise<void> {
    return this.request(`/api/v1/conversations/${encodeURIComponent(conversationId)}/read-cursor`, {
      method: "PUT",
      body: JSON.stringify({ sequence })
    });
  }

  createAttachment(file: File, checksum: string): Promise<AttachmentIntentResponse> {
    return this.request("/api/v1/attachments", {
      method: "POST",
      body: JSON.stringify({
        file_name: file.name,
        content_type: attachmentContentType(file),
        byte_size: file.size,
        checksum_sha256: checksum
      })
    });
  }

  completeAttachment(id: string): Promise<Attachment> {
    return this.request<DataResponse<Attachment>>(
      `/api/v1/attachments/${encodeURIComponent(id)}/complete`,
      { method: "POST" }
    ).then((response) => response.data);
  }

  attachmentDownload(id: string): Promise<AttachmentDownloadResponse> {
    return this.request(`/api/v1/attachments/${encodeURIComponent(id)}`);
  }

  async logout(): Promise<void> {
    try {
      await this.request("/api/v1/sessions/current", { method: "DELETE" });
    } finally {
      this.updateSession(null);
    }
  }

  refreshSession(): Promise<Session | null> {
    return this.refresh();
  }

  private async request<T = void>(path: string, options: RequestOptions = {}): Promise<T> {
    const headers = new Headers(options.headers);
    headers.set("Accept", "application/json");
    if (options.body && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    if (this.session?.access_token) {
      headers.set("Authorization", `Bearer ${this.session.access_token}`);
    }

    const response = await fetch(this.url(path), { ...options, headers });
    const shouldRetry = options.retryAuthentication !== false;
    if (response.status === 401 && shouldRetry && this.session?.refresh_token) {
      const refreshed = await this.refresh();
      if (refreshed) {
        return this.request<T>(path, { ...options, retryAuthentication: false });
      }
    }

    if (response.status === 204) {
      return undefined as T;
    }

    const contentType = response.headers.get("content-type") || "";
    const payload: unknown = contentType.includes("application/json")
      ? await response.json()
      : await response.text();

    if (!response.ok) {
      const envelope = typeof payload === "object" && payload ? (payload as ErrorEnvelope) : {};
      throw new ApiError(
        response.status,
        envelope.error?.code || "request_failed",
        envelope.error?.detail || `Request failed with status ${response.status}`,
        envelope.error?.meta
      );
    }

    return payload as T;
  }

  private refresh(): Promise<Session | null> {
    if (!this.refreshPromise) {
      this.refreshPromise = this.performRefresh().finally(() => {
        this.refreshPromise = null;
      });
    }
    return this.refreshPromise;
  }

  private async performRefresh(): Promise<Session | null> {
    const refreshToken = this.session?.refresh_token;
    if (!refreshToken) return null;

    try {
      const response = await fetch(this.url("/api/v1/sessions/refresh"), {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/json" },
        body: JSON.stringify({ refresh_token: refreshToken })
      });
      if (!response.ok) throw new Error("Refresh rejected");
      const session = withReceivedAt((await response.json()) as Session);
      this.updateSession(session);
      return session;
    } catch {
      this.updateSession(null);
      return null;
    }
  }

  private updateSession(session: Session | null): void {
    this.session = session;
    this.onSession(session);
  }

  private url(path: string): string {
    return `${this.baseUrl.replace(/\/$/, "")}${path}`;
  }
}

export async function sha256(file: File): Promise<string> {
  const digest = await window.crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function uploadToPresignedTarget(
  descriptor: UploadDescriptor,
  file: File
): Promise<void> {
  const url = descriptor.url || descriptor.upload_url || descriptor.href;
  if (!url) throw new Error("The object store did not return an upload URL");

  let body: BodyInit = file;
  const headers = new Headers(descriptor.headers);
  if (descriptor.fields && Object.keys(descriptor.fields).length > 0) {
    const form = new FormData();
    Object.entries(descriptor.fields).forEach(([key, value]) => form.append(key, value));
    form.append("file", file);
    body = form;
  } else if (!headers.has("content-type")) {
    headers.set("content-type", attachmentContentType(file));
  }

  const response = await fetch(url, {
    method: descriptor.method || (descriptor.fields ? "POST" : "PUT"),
    headers,
    body
  });
  if (!response.ok) throw new Error(`Object upload failed with status ${response.status}`);
}

export function downloadUrl(descriptor: UploadDescriptor): string | null {
  return descriptor.url || descriptor.upload_url || descriptor.href || null;
}

function attachmentContentType(file: File): string {
  if (file.type) return file.type;
  const extension = file.name.toLowerCase().split(".").pop();
  const known: Record<string, string> = {
    csv: "text/csv",
    gif: "image/gif",
    jpeg: "image/jpeg",
    jpg: "image/jpeg",
    json: "application/json",
    md: "text/markdown",
    pdf: "application/pdf",
    png: "image/png",
    svg: "image/svg+xml",
    txt: "text/plain",
    webp: "image/webp",
    zip: "application/zip"
  };
  return (extension && known[extension]) || "application/octet-stream";
}

function withReceivedAt<T extends Session>(session: T): T {
  return { ...session, received_at: Date.now() };
}
