import type { CallMediaKind, CallSessionResponse, DataResponse, ListResponse } from "../../types";
import type { Meeting, MeetingInput, MeetingsQuery, UpdateMeetingInput } from "../../types/meetings";
import type { ApiRequest } from "../contracts";

export function createMeetingsApi(request: ApiRequest) {
  return {
    getMeeting(id: string): Promise<Meeting> {
      return request<DataResponse<Meeting>>(`/api/v1/meetings/${encodeURIComponent(id)}`)
        .then((response) => response.data);
    },

    meetings(query: MeetingsQuery): Promise<Meeting[]> {
      const params = new URLSearchParams({ from: query.from, to: query.to });
      return request<ListResponse<Meeting>>(`/api/v1/meetings?${params.toString()}`)
        .then((response) => response.data);
    },

    createMeeting(conversationId: string, input: MeetingInput): Promise<Meeting> {
      return request<DataResponse<Meeting>>(
        `/api/v1/conversations/${encodeURIComponent(conversationId)}/meetings`,
        { method: "POST", body: JSON.stringify(input) }
      ).then((response) => response.data);
    },

    updateMeeting(id: string, input: UpdateMeetingInput): Promise<Meeting> {
      return request<DataResponse<Meeting>>(`/api/v1/meetings/${encodeURIComponent(id)}`, {
        method: "PATCH", body: JSON.stringify(input)
      }).then((response) => response.data);
    },

    cancelMeeting(id: string, expectedVersion: number): Promise<Meeting> {
      return request<DataResponse<Meeting>>(`/api/v1/meetings/${encodeURIComponent(id)}/cancel`, {
        method: "POST", body: JSON.stringify({ expected_version: expectedVersion })
      }).then((response) => response.data);
    },

    meetingCalendar(id: string): Promise<string> {
      return request<DataResponse<{ ics: string; filename: string }>>(
        `/api/v1/meetings/${encodeURIComponent(id)}/calendar`
      ).then((response) => response.data.ics);
    },

    startMeeting(id: string, occurrenceId: string, mediaKind: CallMediaKind): Promise<CallSessionResponse> {
      return request<CallSessionResponse>(
        `/api/v1/meetings/${encodeURIComponent(id)}/occurrences/${encodeURIComponent(occurrenceId)}/start`,
        { method: "POST", body: JSON.stringify({ media_kind: mediaKind }) }
      );
    }
  };
}

export type MeetingsApi = ReturnType<typeof createMeetingsApi>;
