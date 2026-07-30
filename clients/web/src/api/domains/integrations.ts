import type { DataResponse, ListResponse, ServiceAccount, WebhookDelivery, WebhookEndpoint } from "../../types";
import type { ApiRequest, CreateServiceAccountInput } from "../contracts";

export function createIntegrationsApi(request: ApiRequest) {
  const api = {
    webhooks(): Promise<WebhookEndpoint[]> {
        return request<ListResponse<WebhookEndpoint>>("/api/v1/admin/webhooks").then(
          (response) => response.data
        );
      },

    createWebhook(input: { name: string; url: string; event_types: string[] }): Promise<{ endpoint: WebhookEndpoint; secret: string }> {
        return request<{ data: WebhookEndpoint; secret: string }>("/api/v1/admin/webhooks", {
          method: "POST",
          body: JSON.stringify(input)
        }).then((response) => ({ endpoint: response.data, secret: response.secret }));
      },

    rotateWebhookSecret(id: string, reason?: string): Promise<{ endpoint: WebhookEndpoint; secret: string }> {
        return request<{ data: WebhookEndpoint; secret: string }>(`/api/v1/admin/webhooks/${encodeURIComponent(id)}/rotate-secret`, {
          method: "POST",
          body: reason ? JSON.stringify({ reason }) : undefined
        }).then(
          (response) => ({ endpoint: response.data, secret: response.secret })
        );
      },

    disableWebhook(id: string, reason?: string): Promise<void> {
        return request(`/api/v1/admin/webhooks/${encodeURIComponent(id)}`, {
          method: "DELETE",
          body: reason ? JSON.stringify({ reason }) : undefined
        });
      },

    webhookDeliveries(): Promise<WebhookDelivery[]> {
        return request<ListResponse<WebhookDelivery>>("/api/v1/admin/webhook-deliveries").then(
          (response) => response.data
        );
      },

    serviceAccounts(): Promise<ServiceAccount[]> {
        return request<ListResponse<ServiceAccount>>("/api/v1/admin/service-accounts").then(
          (response) => response.data
        );
      },

    createServiceAccount(input: CreateServiceAccountInput): Promise<{ account: ServiceAccount; credential: string }> {
        return request<{ data: ServiceAccount; credential: string }>("/api/v1/admin/service-accounts", {
          method: "POST",
          body: JSON.stringify(input)
        }).then((response) => ({ account: response.data, credential: response.credential }));
      },

    rotateServiceAccount(id: string, version: number, reason: string): Promise<{ account: ServiceAccount; credential: string }> {
        return request<{ data: ServiceAccount; credential: string }>(`/api/v1/admin/service-accounts/${encodeURIComponent(id)}/rotate`, {
          method: "POST",
          body: JSON.stringify({ version, reason })
        }).then((response) => ({ account: response.data, credential: response.credential }));
      },

    revokeServiceAccount(id: string, version: number, reason: string): Promise<ServiceAccount> {
        return request<DataResponse<ServiceAccount>>(`/api/v1/admin/service-accounts/${encodeURIComponent(id)}/revoke`, {
          method: "POST",
          body: JSON.stringify({ version, reason })
        }).then((response) => response.data);
      },

    replayWebhookDelivery(id: string): Promise<WebhookDelivery> {
        return request<DataResponse<WebhookDelivery>>(`/api/v1/admin/webhook-deliveries/${encodeURIComponent(id)}/replay`, { method: "POST" }).then(
          (response) => response.data
        );
      }
  };
  return api;
}

export type IntegrationsApi = ReturnType<typeof createIntegrationsApi>;
