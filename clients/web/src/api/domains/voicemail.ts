import type { ApiRequest } from "../contracts";
import type { DataResponse } from "../../types";
import type { VoicemailMailbox, VoicemailMailboxInput, VoicemailMessage, VoicemailPage, VoicemailPlayback } from "../../features/telephony/voicemailTypes";
export function createVoicemailApi(request: ApiRequest) {
  const item = (id: string) => `/api/v1/telephony/voicemails/${encodeURIComponent(id)}`;
  return {
    voicemails: (options: { limit?: number; cursor?: string | null } = {}): Promise<VoicemailPage> => {
      const query = new URLSearchParams({ limit: String(options.limit ?? 30) });
      if (options.cursor) query.set("cursor", options.cursor);
      return request(`/api/v1/telephony/voicemails?${query}`);
    },
    voicemailPlayback: (id: string) => request<DataResponse<VoicemailPlayback>>(`${item(id)}/playback`).then(response => response.data),
    markVoicemailRead: (id: string) => request<DataResponse<VoicemailMessage>>(`${item(id)}/read`, { method: "POST" }).then(response => response.data),
    deleteVoicemail: (id: string) => request<DataResponse<{ status: "deleting" }>>(item(id), { method: "DELETE" }).then(response => response.data),
    voicemailMailbox: () => request<DataResponse<VoicemailMailbox | null>>("/api/v1/admin/telephony/mailbox").then(response => response.data),
    saveVoicemailMailbox: (input: VoicemailMailboxInput) => request<DataResponse<VoicemailMailbox>>("/api/v1/admin/telephony/mailbox", { method: "PUT", body: JSON.stringify(input) }).then(response => response.data)
  };
}
export type VoicemailApi = ReturnType<typeof createVoicemailApi>;
