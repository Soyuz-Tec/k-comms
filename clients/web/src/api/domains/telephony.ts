import type { ApiRequest } from "../contracts";
import type { DataResponse } from "../../types";
import type { PhoneCall, PhoneCallsPage, PhoneConfiguration, PhoneNumberInput, PhoneSession } from "../../features/telephony/types";

export function createTelephonyApi(request: ApiRequest) {
  const callPath = (id: string) => `/api/v1/telephony/calls/${encodeURIComponent(id)}`;
  return {
    phoneConfiguration: () => request<DataResponse<PhoneConfiguration>>("/api/v1/telephony/config").then(({ data }) => data),
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
