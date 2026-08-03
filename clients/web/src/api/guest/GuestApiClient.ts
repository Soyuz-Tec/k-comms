import type {
  Call,
  CallMediaKind,
  CallSessionResponse,
  Conversation,
  ConversationMembership,
  DataResponse,
  GuestAccountConversionResult,
  GuestLinkPreview,
  GuestSession,
  ListResponse,
  Message,
  MessagePage,
  RetainedSenderLabel,
  WhiteboardElementData,
  WhiteboardOperation,
  WhiteboardOperationPage
} from "../../types";
import type { ApiRequestOptions, SendMessageInput } from "../contracts";
import { ApiError, retryAfterSeconds } from "../errors";
import { resolveSenderLabelBatches } from "../senderLabels";
import { sameGuestSessionIdentity } from "../sessionIdentity";
import { fetchWithApiDeadline } from "../transport/deadline";
import {
  normalizeAccountConversion,
  normalizeGuestSession,
  normalizeInstantRoomResult,
  firstString,
  readObject,
  unwrapData,
  unwrapList,
  unwrapNullableData
} from "./normalizers";

interface ErrorEnvelope {
  error?: {
    code?: string;
    detail?: string;
    meta?: unknown;
  };
}

type RequestOptions = ApiRequestOptions;

export class GuestApiClient {
  private session: GuestSession | null;
  private refreshPromise: Promise<GuestSession | null> | null = null;
  private refreshController: AbortController | null = null;
  private sessionGeneration = 0;

  constructor(
    private readonly baseUrl: string,
    initialSession: GuestSession | null,
    private readonly onSession: (
      session: GuestSession | null,
      reason?: "access_ended" | "logout"
    ) => void
  ) {
    this.session = initialSession;
  }

  setSession(session: GuestSession | null): void {
    const credentialsChanged =
      this.session?.access_token !== session?.access_token ||
      this.session?.refresh_token !== session?.refresh_token;
    if (!sameGuestSessionIdentity(this.session, session)) {
      this.sessionGeneration += 1;
    }
    if (credentialsChanged) {
      this.refreshController?.abort();
    }
    this.session = session;
  }

  previewGuestLink(token: string): Promise<GuestLinkPreview> {
    return this.request<DataResponse<GuestLinkPreview> | GuestLinkPreview>(
      "/api/v1/guest-links/preview",
      {
        method: "POST",
        body: JSON.stringify({ token }),
        retryAuthentication: false
      }
    ).then(unwrapData);
  }

  joinGuest(input: {
    token: string;
    display_name: string;
    device: { name: string; platform: "web" };
  }): Promise<GuestSession> {
    return this.request<unknown>("/api/v1/guest-sessions", {
      method: "POST",
      body: JSON.stringify(input),
      retryAuthentication: false
    }).then((payload) => {
      const session = normalizeGuestSession(payload);
      this.updateSession(session);
      return session;
    });
  }

  joinInstantRoom(input: {
    token: string;
    display_name?: string;
    device?: { name: string; platform: "web" };
  }, idempotencyKey: string): Promise<GuestSession> {
    return this.request<unknown>("/api/v1/instant-room-sessions", {
      method: "POST",
      headers: { "Idempotency-Key": idempotencyKey },
      body: JSON.stringify(input),
      retryAuthentication: false
    }).then((payload) => {
      const result = normalizeInstantRoomResult(payload);
      if (!result.guest_session) {
        throw new Error("The server did not return a guest room session.");
      }
      this.updateSession(result.guest_session);
      return result.guest_session;
    });
  }

  conversation(): Promise<Conversation> {
    return this.request<DataResponse<Conversation> | Conversation>(
      "/api/v1/guest/conversation"
    ).then(unwrapData);
  }

  conversationMembers(): Promise<ConversationMembership[]> {
    return this.request<ListResponse<ConversationMembership> | ConversationMembership[]>(
      "/api/v1/guest/conversation/members"
    ).then(unwrapList);
  }

  messages(afterSequence = 0, limit = 200): Promise<MessagePage> {
    const query = new URLSearchParams({
      after_sequence: String(afterSequence),
      limit: String(limit),
      include: "sender_labels"
    });
    return this.request(`/api/v1/guest/conversation/messages?${query.toString()}`);
  }

  messageSenderLabels(messageIds: string[]): Promise<RetainedSenderLabel[]> {
    return resolveSenderLabelBatches(messageIds, (batch) =>
      this.request<DataResponse<RetainedSenderLabel[]>>(
        "/api/v1/guest/conversation/message-sender-labels",
        {
          method: "POST",
          body: JSON.stringify({ message_ids: batch })
        }
      ).then((response) => response.data)
    );
  }

  sendMessage(input: SendMessageInput): Promise<Message> {
    const { client_message_id: idempotencyKey, ...body } = input;
    return this.request<DataResponse<Message> | Message>(
      "/api/v1/guest/conversation/messages",
      {
        method: "POST",
        headers: { "Idempotency-Key": idempotencyKey },
        body: JSON.stringify(body)
      }
    ).then(unwrapData);
  }

  markRead(sequence: number): Promise<void> {
    return this.request("/api/v1/guest/conversation/read-cursor", {
      method: "PUT",
      body: JSON.stringify({ sequence })
    });
  }

  whiteboardOperations(
    _conversationId: string,
    afterSequence = 0,
    limit = 500
  ): Promise<WhiteboardOperationPage> {
    const query = new URLSearchParams({
      after_sequence: String(Math.max(0, afterSequence)),
      limit: String(Math.max(1, Math.min(limit, 500))),
      snapshot: "true"
    });
    return this.request(
      `/api/v1/guest/conversation/whiteboard/operations?${query.toString()}`
    );
  }

  appendWhiteboardSceneUpdate(
    _conversationId: string,
    clientOperationId: string,
    baseSequence: number,
    elements: WhiteboardElementData[]
  ): Promise<WhiteboardOperation> {
    return this.request<DataResponse<WhiteboardOperation>>(
      "/api/v1/guest/conversation/whiteboard/operations",
      {
        method: "POST",
        headers: { "Idempotency-Key": clientOperationId },
        body: JSON.stringify({
          kind: "scene.update",
          base_sequence: Math.max(0, baseSequence),
          payload: { elements }
        })
      }
    ).then((response) => response.data);
  }

  clearWhiteboard(
    _conversationId: string,
    clientOperationId: string
  ): Promise<WhiteboardOperation> {
    return this.request<DataResponse<WhiteboardOperation>>(
      "/api/v1/guest/conversation/whiteboard/operations",
      {
        method: "POST",
        headers: { "Idempotency-Key": clientOperationId },
        body: JSON.stringify({ kind: "board.clear", payload: {} })
      }
    ).then((response) => response.data);
  }

  socketTicket(): Promise<{ ticket: string; expires_in: number }> {
    return this.request<
      DataResponse<{ ticket: string; expires_in: number }> |
      { ticket: string; expires_in: number }
    >("/api/v1/guest/socket-tickets", { method: "POST" }).then(unwrapData);
  }

  call(): Promise<Call | null> {
    return this.request<DataResponse<Call | null> | Call | null>(
      "/api/v1/guest/conversation/call"
    ).then(unwrapNullableData);
  }

  startCall(_conversationId: string, mediaKind: CallMediaKind): Promise<CallSessionResponse> {
    return this.request("/api/v1/guest/conversation/calls", {
      method: "POST",
      body: JSON.stringify({ media_kind: mediaKind })
    });
  }

  joinCall(_conversationId: string, callId: string): Promise<CallSessionResponse> {
    return this.request(
      `/api/v1/guest/conversation/calls/${encodeURIComponent(callId)}/join`,
      { method: "POST" }
    );
  }

  endCall(_conversationId: string, callId: string): Promise<Call> {
    return this.request<DataResponse<Call> | Call>(
      `/api/v1/guest/conversation/calls/${encodeURIComponent(callId)}/end`,
      { method: "POST" }
    ).then(unwrapData);
  }

  convertAccount(input: {
    email: string;
    password: string;
    verification_code?: string;
    display_name?: string;
  }): Promise<GuestAccountConversionResult> {
    return this.request<unknown>("/api/v1/guest/account", {
      method: "POST",
      body: JSON.stringify(input)
    }).then(normalizeAccountConversion);
  }

  async logout(): Promise<void> {
    const revocation = this.session
      ? this.request("/api/v1/guest/sessions/current", {
        method: "DELETE",
        keepalive: true,
        retryAuthentication: false
      }).catch(() => undefined)
      : Promise.resolve();
    this.updateSession(null, "logout");
    await revocation;
  }

  private async request<T = void>(path: string, options: RequestOptions = {}): Promise<T> {
    const requestGeneration = this.sessionGeneration;
    const requestSession = this.session;
    const requestAccessToken = this.session?.access_token;
    const requestRefreshToken = this.session?.refresh_token;
    const authenticatedRequest = Boolean(requestAccessToken);
    const headers = new Headers(options.headers);
    headers.set("Accept", "application/json");
    if (options.body && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    if (requestAccessToken) {
      headers.set("Authorization", `Bearer ${requestAccessToken}`);
    }

    const { response, body: payload } = await fetchWithApiDeadline(
      this.url(path),
      { ...options, headers },
      async (result) => {
        if (result.status === 204) return undefined;
        const contentType = result.headers.get("content-type") || "";
        return contentType.includes("application/json")
          ? result.json()
          : result.text();
      }
    );
    const shouldRetry = options.retryAuthentication !== false;
    if (
      response.status === 401 &&
      shouldRetry &&
      requestRefreshToken &&
      this.sessionMatches(
        requestGeneration,
        requestSession
      )
    ) {
      if (this.session?.refresh_token !== requestRefreshToken) {
        return this.request<T>(path, {
          ...options,
          retryAuthentication: false
        });
      }
      const refreshed = await this.refresh();
      if (
        refreshed &&
        this.session?.access_token === refreshed.access_token &&
        this.session?.refresh_token === refreshed.refresh_token
      ) {
        return this.request<T>(path, { ...options, retryAuthentication: false });
      }
    }
    if (response.status === 204) {
      if (
        authenticatedRequest &&
        !this.sessionMatches(requestGeneration, requestSession)
      ) {
        throw new ApiError(
          409,
          "session_changed",
          "Your guest visit changed before the request completed. Try again."
        );
      }
      return undefined as T;
    }

    if (!response.ok) {
      const envelope = typeof payload === "object" && payload ? (payload as ErrorEnvelope) : {};
      throw new ApiError(
        response.status,
        envelope.error?.code || "request_failed",
        envelope.error?.detail || `Request failed with status ${response.status}`,
        envelope.error?.meta,
        retryAfterSeconds(response.headers.get("retry-after"))
      );
    }
    if (
      authenticatedRequest &&
      !this.sessionMatches(requestGeneration, requestSession)
    ) {
      throw new ApiError(
        409,
        "session_changed",
        "Your guest visit changed before the request completed. Try again."
      );
    }
    return payload as T;
  }

  private refresh(): Promise<GuestSession | null> {
    if (!this.refreshPromise) {
      this.refreshPromise = this.performRefresh().finally(() => {
        this.refreshPromise = null;
        this.refreshController = null;
      });
    }
    return this.refreshPromise;
  }

  private async performRefresh(): Promise<GuestSession | null> {
    const refreshToken = this.session?.refresh_token;
    if (!refreshToken) return null;
    const generation = this.sessionGeneration;
    const controller = new AbortController();
    this.refreshController = controller;
    let response: Response;
    let payload: unknown;
    try {
      ({ response, body: payload } = await fetchWithApiDeadline(
        this.url("/api/v1/guest/sessions/refresh"),
        {
          method: "POST",
          headers: { Accept: "application/json", "Content-Type": "application/json" },
          body: JSON.stringify({ refresh_token: refreshToken }),
          signal: controller.signal
        },
        async (result) => result.ok ? result.json() : null
      ));
    } catch (error) {
      if (!this.refreshMatches(generation, refreshToken)) return null;
      throw error;
    }
    if (!this.refreshMatches(generation, refreshToken)) return null;
    if (!response.ok) {
      if ([400, 401, 403].includes(response.status)) {
        this.updateSession(null, "access_ended");
        return null;
      }
      throw new Error(`Guest session refresh is temporarily unavailable (${response.status})`);
    }

    const previous = this.session;
    if (!previous) return null;
    const refreshed = normalizeGuestSession({
      ...(readObject(payload) || {}),
      conversation: readObject(payload)?.conversation || previous.conversation,
      capabilities: readObject(payload)?.capabilities || previous.capabilities,
      admission: readObject(payload)?.admission || previous.admission,
      room:
        readObject(payload)?.room ||
        readObject(payload)?.instant_room ||
        previous.instant_room,
      share_url: firstString(
        readObject(payload)?.share_url,
        previous.share_url
      )
    });
    this.updateSession(refreshed);
    return refreshed;
  }

  private updateSession(
    session: GuestSession | null,
    reason?: "access_ended" | "logout"
  ): void {
    this.setSession(session);
    if (reason) {
      this.onSession(session, reason);
    } else {
      this.onSession(session);
    }
  }

  private sessionMatches(
    generation: number,
    session: GuestSession | null
  ): boolean {
    return generation === this.sessionGeneration &&
      sameGuestSessionIdentity(this.session, session);
  }

  private refreshMatches(generation: number, refreshToken: string): boolean {
    return generation === this.sessionGeneration &&
      this.session?.refresh_token === refreshToken;
  }

  private url(path: string): string {
    return `${this.baseUrl.replace(/\/$/, "")}${path}`;
  }
}
