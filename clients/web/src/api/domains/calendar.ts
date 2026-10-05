import type { ApiRequest } from "../contracts";
import type { DataResponse } from "../../types";
import type { CalendarConnection, CalendarConnectionsResponse, CalendarExport, CalendarProvider } from "../../types/calendarSync";
export function createCalendarApi(request: ApiRequest) {
  const post = <T,>(path: string, body: unknown) => request<DataResponse<T>>(path,
    { method: "POST", body: JSON.stringify(body) }).then(response => response.data);
  return {
    calendarConnections: () => request<CalendarConnectionsResponse>("/api/v1/calendar/connections"),
    authorizeCalendar: (provider: CalendarProvider, exportPolicyVersion: number, purpose: "export" | "cleanup") =>
      post<{ provider: CalendarProvider; authorization_url: string; expires_at: string }>(
        `/api/v1/calendar/oauth/${provider}/authorize`, { export_policy_version: exportPolicyVersion, purpose }),
    unlinkCalendar: (id: string, version: number) => post<CalendarConnection>(
      `/api/v1/calendar/connections/${encodeURIComponent(id)}/unlink`, { version }),
    calendarExports: (meetingId: string) => request<{ data: CalendarExport[]; meta: { truncated: boolean } }>(
      `/api/v1/calendar/exports?meeting_id=${encodeURIComponent(meetingId)}`),
    createCalendarExport: (connectionId: string, meetingId: string, meetingVersion: number) => post<CalendarExport>(
      "/api/v1/calendar/exports", { connection_id: connectionId, meeting_id: meetingId, meeting_version: meetingVersion }),
    resolveCalendarExport: (id: string, version: number, decision: "reexport_current" | "stop_syncing", meetingVersion: number) =>
      post<CalendarExport>(`/api/v1/calendar/exports/${encodeURIComponent(id)}/resolve`,
        { version, decision, meeting_version: meetingVersion })
  };
}
export type CalendarApi = ReturnType<typeof createCalendarApi>;
