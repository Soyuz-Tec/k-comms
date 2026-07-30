import type { Session } from "../../types";
import type {
  ApiDownload,
  ApiRequest,
  ApiRequestOptions,
  AuditExportFile
} from "../contracts";
import { ApiError, retryAfterSeconds } from "../errors";
import {
  sameMemberSessionIdentity,
  withReceivedAt
} from "../sessionIdentity";
import {
  attachmentFilename,
  nonNegativeHeaderInteger
} from "../uploads";
import { fetchWithApiDeadline } from "./deadline";

interface ErrorEnvelope {
  error?: {
    code?: string;
    detail?: string;
    meta?: unknown;
  };
}

export class MemberSessionTransport {
  private session: Session | null;
  private refreshPromise: Promise<Session | null> | null = null;
  private refreshController: AbortController | null = null;
  private sessionGeneration = 0;

  readonly request: ApiRequest = <T = void>(
    path: string,
    options: ApiRequestOptions = {}
  ) => this.executeRequest<T>(path, options);

  readonly download: ApiDownload = (
    path: string,
    options: ApiRequestOptions = {}
  ) => this.executeDownload(path, options);

  constructor(
    private readonly baseUrl: string,
    initialSession: Session | null,
    private readonly onSession: (session: Session | null) => void
  ) {
    this.session = initialSession;
  }

  setSession(session: Session | null): void {
    const credentialsChanged =
      this.session?.access_token !== session?.access_token ||
      this.session?.refresh_token !== session?.refresh_token;

    if (!sameMemberSessionIdentity(this.session, session)) {
      this.sessionGeneration += 1;
    }
    if (credentialsChanged) {
      this.refreshController?.abort();
    }
    this.session = session;
  }

  async logout(): Promise<void> {
    const revocation = this.session
      ? this.request("/api/v1/sessions/current", {
          method: "DELETE",
          keepalive: true,
          retryAuthentication: false
        }).catch(() => undefined)
      : Promise.resolve();

    this.updateSession(null);
    await revocation;
  }

  refreshSession(): Promise<Session | null> {
    return this.refresh();
  }

  private async executeRequest<T>(
    path: string,
    options: ApiRequestOptions
  ): Promise<T> {
    const requestGeneration = this.sessionGeneration;
    const requestSession = this.session;
    const requestAccessToken = this.session?.access_token;
    const requestRefreshToken = this.session?.refresh_token;
    const authenticatedRequest =
      !options.skipAuthentication && Boolean(requestAccessToken);
    const headers = new Headers(options.headers);
    headers.set("Accept", "application/json");
    if (options.body && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    if (!options.skipAuthentication && requestAccessToken) {
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
      this.sessionMatches(requestGeneration, requestSession)
    ) {
      if (this.session?.refresh_token !== requestRefreshToken) {
        return this.executeRequest<T>(path, {
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
        return this.executeRequest<T>(path, {
          ...options,
          retryAuthentication: false
        });
      }
    }

    if (response.status === 204) {
      if (
        authenticatedRequest &&
        !this.sessionMatches(requestGeneration, requestSession)
      ) {
        throw sessionChangedError();
      }
      return undefined as T;
    }

    if (!response.ok) {
      throw responseError(response, payload);
    }

    if (
      authenticatedRequest &&
      !this.sessionMatches(requestGeneration, requestSession)
    ) {
      throw sessionChangedError();
    }

    return payload as T;
  }

  private async executeDownload(
    path: string,
    options: ApiRequestOptions
  ): Promise<AuditExportFile> {
    const requestGeneration = this.sessionGeneration;
    const requestSession = this.session;
    const requestAccessToken = this.session?.access_token;
    const requestRefreshToken = this.session?.refresh_token;
    const headers = new Headers(options.headers);
    headers.set("Accept", "text/csv");
    if (options.body && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    if (requestAccessToken) {
      headers.set("Authorization", `Bearer ${requestAccessToken}`);
    }

    const response = await fetch(this.url(path), { ...options, headers });
    const shouldRetry = options.retryAuthentication !== false;
    if (
      response.status === 401 &&
      shouldRetry &&
      requestRefreshToken &&
      this.sessionMatches(requestGeneration, requestSession)
    ) {
      if (this.session?.refresh_token !== requestRefreshToken) {
        return this.executeDownload(path, {
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
        return this.executeDownload(path, {
          ...options,
          retryAuthentication: false
        });
      }
    }

    if (!response.ok) {
      const contentType = response.headers.get("content-type") || "";
      const payload: unknown = contentType.includes("application/json")
        ? await response.json()
        : await response.text();
      throw responseError(response, payload);
    }

    const blob = await response.blob();
    if (!this.sessionMatches(requestGeneration, requestSession)) {
      throw new ApiError(
        409,
        "session_changed",
        "Your account changed before the export completed. Run the export again."
      );
    }

    return {
      blob,
      filename: attachmentFilename(
        response.headers.get("content-disposition")
      ),
      count: nonNegativeHeaderInteger(
        response.headers.get("x-export-row-count")
      ),
      truncated: response.headers.get("x-export-truncated") === "true"
    };
  }

  private refresh(): Promise<Session | null> {
    if (!this.refreshPromise) {
      this.refreshPromise = this.performRefresh().finally(() => {
        this.refreshPromise = null;
        this.refreshController = null;
      });
    }
    return this.refreshPromise;
  }

  private async performRefresh(): Promise<Session | null> {
    const refreshToken = this.session?.refresh_token;
    if (!refreshToken) return null;
    const generation = this.sessionGeneration;
    const controller = new AbortController();
    this.refreshController = controller;

    let response: Response;
    let body: unknown;
    try {
      ({ response, body } = await fetchWithApiDeadline(
        this.url("/api/v1/sessions/refresh"),
        {
          method: "POST",
          headers: {
            Accept: "application/json",
            "Content-Type": "application/json"
          },
          body: JSON.stringify({ refresh_token: refreshToken }),
          signal: controller.signal
        },
        async (result) => (result.ok ? result.json() : null)
      ));
    } catch (error) {
      if (!this.refreshMatches(generation, refreshToken)) return null;
      throw error;
    }
    if (!this.refreshMatches(generation, refreshToken)) return null;
    if (!response.ok) {
      if ([400, 401, 403].includes(response.status)) {
        this.updateSession(null);
        return null;
      }
      throw new Error(
        `Session refresh is temporarily unavailable (${response.status})`
      );
    }
    const session = withReceivedAt(body as Session);
    this.updateSession(session);
    return session;
  }

  private updateSession(session: Session | null): void {
    this.setSession(session);
    this.onSession(session);
  }

  private sessionMatches(
    generation: number,
    session: Session | null
  ): boolean {
    return (
      generation === this.sessionGeneration &&
      sameMemberSessionIdentity(this.session, session)
    );
  }

  private refreshMatches(generation: number, refreshToken: string): boolean {
    return (
      generation === this.sessionGeneration &&
      this.session?.refresh_token === refreshToken
    );
  }

  private url(path: string): string {
    return `${this.baseUrl.replace(/\/$/, "")}${path}`;
  }
}

function responseError(response: Response, payload: unknown): ApiError {
  const envelope =
    typeof payload === "object" && payload ? (payload as ErrorEnvelope) : {};
  return new ApiError(
    response.status,
    envelope.error?.code || "request_failed",
    envelope.error?.detail ||
      `Request failed with status ${response.status}`,
    envelope.error?.meta,
    retryAfterSeconds(response.headers.get("retry-after"))
  );
}

function sessionChangedError(): ApiError {
  return new ApiError(
    409,
    "session_changed",
    "Your account changed before the request completed. Try again."
  );
}
