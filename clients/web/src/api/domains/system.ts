import type { HealthStatus, ServiceStatus } from "../../types";
import type { ApiRequest } from "../contracts";

export function createSystemApi(request: ApiRequest) {
  const api = {
    status(): Promise<ServiceStatus> {
        return request<ServiceStatus>("/api/v1/status", { retryAuthentication: false });
      },

    readiness(): Promise<HealthStatus> {
        return request<HealthStatus>("/health/ready", { retryAuthentication: false });
      }
  };
  return api;
}

export type SystemApi = ReturnType<typeof createSystemApi>;
