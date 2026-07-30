import type { AccountSession, Conversation, DataResponse, Device, DirectConversationResponse, DirectoryPeoplePage, ListResponse, MeResponse, Session, User } from "../../types";
import type { ApiRequest, BootstrapInput, LoginInput } from "../contracts";

interface AccountsApiSupport {
  withReceivedAt: <T extends Session>(session: T) => T;
}

export function createAccountsApi(
  request: ApiRequest,
  { withReceivedAt }: AccountsApiSupport
) {
  const api = {
    bootstrap(input: BootstrapInput): Promise<Session & { conversation: Conversation }> {
        return request<Session & { conversation: Conversation }>("/api/v1/bootstrap", {
          method: "POST",
          body: JSON.stringify(input),
          retryAuthentication: false
        }).then(withReceivedAt);
      },

    login(input: LoginInput): Promise<Session> {
        return request<Session>("/api/v1/sessions", {
          method: "POST",
          body: JSON.stringify(input),
          retryAuthentication: false
        }).then(withReceivedAt);
      },

    requestPasswordRecovery(input: { tenant_slug: string; email: string }): Promise<void> {
        return request("/api/v1/password-recovery/requests", {
          method: "POST",
          body: JSON.stringify(input),
          retryAuthentication: false
        });
      },

    resetPassword(input: { token: string; new_password: string }): Promise<void> {
        return request("/api/v1/password-recovery/resets", {
          method: "POST",
          body: JSON.stringify(input),
          retryAuthentication: false
        });
      },

    acceptInvitation(input: { token: string; display_name: string; password: string }): Promise<User> {
        return request<DataResponse<User>>("/api/v1/invitations/accept", {
          method: "POST",
          body: JSON.stringify(input),
          retryAuthentication: false
        }).then((response) => response.data);
      },

    me(): Promise<MeResponse> {
        return request("/api/v1/me");
      },

    updateProfile(input: { display_name: string }): Promise<User> {
        return request<DataResponse<User>>("/api/v1/me/profile", {
          method: "PATCH",
          body: JSON.stringify(input)
        }).then((response) => response.data);
      },

    changePassword(input: { current_password: string; new_password: string }): Promise<void> {
        return request("/api/v1/me/password", { method: "PUT", body: JSON.stringify(input) });
      },

    stepUp(currentPassword: string): Promise<{ step_up_at: string }> {
        return request<DataResponse<{ step_up_at: string }>>("/api/v1/me/step-up", {
          method: "POST",
          body: JSON.stringify({ current_password: currentPassword })
        }).then((response) => response.data);
      },

    socketTicket(): Promise<{ ticket: string; expires_in: number }> {
        return request<DataResponse<{ ticket: string; expires_in: number }>>("/api/v1/socket-tickets", {
          method: "POST"
        }).then((response) => response.data);
      },

    devices(): Promise<Device[]> {
        return request<ListResponse<Device>>("/api/v1/me/devices").then(
          (response) => response.data
        );
      },

    revokeDevice(id: string): Promise<void> {
        return request(`/api/v1/me/devices/${encodeURIComponent(id)}`, { method: "DELETE" });
      },

    sessions(): Promise<AccountSession[]> {
        return request<ListResponse<AccountSession>>("/api/v1/me/sessions").then(
          (response) => response.data
        );
      },

    revokeSession(id: string): Promise<void> {
        return request(`/api/v1/me/sessions/${encodeURIComponent(id)}`, { method: "DELETE" });
      },

    users(): Promise<User[]> {
        return request<ListResponse<User>>("/api/v1/users").then((response) => response.data);
      },

    directoryUsers(
        query = "",
        limit = 25,
        cursor?: string | null
      ): Promise<DirectoryPeoplePage> {
        const params = new URLSearchParams({ q: query, limit: String(limit) });
        if (cursor) params.set("cursor", cursor);
        return request(`/api/v1/directory/users?${params.toString()}`);
      },

    directConversation(userId: string): Promise<DirectConversationResponse> {
        return request("/api/v1/direct-conversations", {
          method: "POST",
          body: JSON.stringify({ user_id: userId })
        });
      }
  };
  return api;
}

export type AccountsApi = ReturnType<typeof createAccountsApi>;
