import type { ApiRequest } from "../contracts";
import type { PhoneProvisioningState, PhoneProvisioningInput, PhoneProvisioningAction, PhoneProvisioningCommand } from "../../features/telephony/provisioning-types";
import type { DataResponse } from "../../types";
import type { PhoneCapabilities, PhoneControlInput, PhoneControlReceipt, PhoneRoute, PhoneRouteInput, PhoneCall, PhoneCallsPage, PhoneConfiguration, PhoneNumberInput, PhoneSession } from "../../features/telephony/types";

export function createTelephonyApi(request: ApiRequest) {
  const callPath = (id: string) => `/api/v1/telephony/calls/${encodeURIComponent(id)}`;
  return {
    phoneProvisioningState: () => request<DataResponse<PhoneProvisioningState>>("/api/v1/admin/telephony/provisioning").then(({ data }) => data),
    inspectPhoneProvisioning: (input: PhoneProvisioningInput) => request<DataResponse<PhoneProvisioningCommand>>("/api/v1/admin/telephony/provisioning/inspect", { method: "POST", body: JSON.stringify(input) }).then(({ data }) => data),
    applyPhoneProvisioning: (id: string, input: PhoneProvisioningAction) => request<DataResponse<PhoneProvisioningCommand>>(`/api/v1/admin/telephony/provisioning/${encodeURIComponent(id)}/apply`, { method: "POST", body: JSON.stringify(input) }).then(({ data }) => data),
    reconcilePhoneProvisioning: (id: string, input: PhoneProvisioningAction) => request<DataResponse<PhoneProvisioningCommand>>(`/api/v1/admin/telephony/provisioning/${encodeURIComponent(id)}/reconcile`, { method: "POST", body: JSON.stringify(input) }).then(({ data }) => data),
    phoneRoutes: () => request<{ data: PhoneRoute[]; limit: number }>("/api/v1/admin/telephony/routes"),
    savePhoneRoute: (input: PhoneRouteInput) => request<DataResponse<PhoneRoute>>("/api/v1/admin/telephony/routes", { method: "PUT", body: JSON.stringify(input) }).then(({ data }) => data),
    phoneCapabilities: () => request<DataResponse<PhoneCapabilities>>("/api/v1/telephony/capabilities").then(({ data }) => data),
    phoneControls: (id: string) => request<{ data: PhoneControlReceipt[]; limit: number }>(`${callPath(id)}/controls`),
    requestPhoneControl: (id: string, input: PhoneControlInput) => request<DataResponse<PhoneControlReceipt>>(`${callPath(id)}/controls`, { method: "POST", body: JSON.stringify(input) }).then(({ data }) => data),
    completePhoneControl: (id: string, commandId: string, status: "submitted" | "unknown") => request<DataResponse<PhoneControlReceipt>>(`${callPath(id)}/controls/${encodeURIComponent(commandId)}/complete`, { method: "POST", body: JSON.stringify({ status }) }).then(({ data }) => data),
    reconcilePhoneControl: (id: string, commandId: string) => request<DataResponse<PhoneControlReceipt>>(`${callPath(id)}/controls/${encodeURIComponent(commandId)}/reconcile`, { method: "POST" }).then(({ data }) => data),
    phoneConfiguration: () => request<DataResponse<PhoneConfiguration>>("/api/v1/telephony/config").then(({ data }) => data),
    phoneAdminConfiguration: () => request<DataResponse<PhoneConfiguration>>("/api/v1/admin/telephony").then(({ data }) => data),
    phoneNumberAssignment: () => request<DataResponse<PhoneConfiguration>>("/api/v1/admin/telephony").then(({ data }) => data.number),
    updatePhoneNumber: (input: PhoneNumberInput) => request<DataResponse<PhoneConfiguration>>("/api/v1/admin/telephony", { method: "PUT", body: JSON.stringify(input) }).then(({ data }) => {
      if (!data.number) throw new Error("The saved phone assignment was not returned. Refresh phone settings before retrying.");
      return data.number;
    }),
    phoneCalls(options: { scope?: "active" | "missed"; limit?: number; cursor?: string | null } = {}): Promise<PhoneCallsPage> {
      const query = new URLSearchParams({ limit: String(options.limit ?? 30) });
      if (options.scope) query.set("scope", options.scope);
      if (options.cursor) query.set("cursor", options.cursor);
      return request(`/api/v1/telephony/calls?${query}`);
    },
    phoneCall: (id: string) => request<DataResponse<PhoneCall>>(callPath(id)).then(({ data }) => data),
    dialPhone: (destination: string, idempotencyKey: string) => request<PhoneSession>("/api/v1/telephony/calls", { method: "POST", body: JSON.stringify({ destination, idempotency_key: idempotencyKey }) }),
    answerPhoneCall: (id: string) => request<PhoneSession>(`${callPath(id)}/answer`, { method: "POST" }),
    joinPhoneCall: (id: string) => request<PhoneSession>(`${callPath(id)}/join`, { method: "POST" }),
    rejectPhoneCall: (id: string) => request<DataResponse<PhoneCall>>(`${callPath(id)}/reject`, { method: "POST" }).then(({ data }) => data),
    endPhoneCall: (id: string) => request<DataResponse<PhoneCall>>(`${callPath(id)}/end`, { method: "POST" }).then(({ data }) => data)
  };
}

export type TelephonyApi = ReturnType<typeof createTelephonyApi>;
