import type { Call, CallMediaKind, CallParticipantState, CallSessionResponse, CallsPageResponse, CallsQueryOptions, DataResponse, ListResponse } from "../../types";
import type { ApiRequest } from "../contracts";

export function createCallsApi(request: ApiRequest) {
  const api = {
    calls(options: CallsQueryOptions = {}): Promise<CallsPageResponse> {
        const query = new URLSearchParams({
          scope: options.scope ?? "recent",
          limit: String(Math.max(1, Math.min(options.limit ?? 25, 100)))
        });
        if (options.media_kind) query.set("media_kind", options.media_kind);
        if (options.cursor) query.set("cursor", options.cursor);
        return request(`/api/v1/calls?${query.toString()}`);
      },

    call(conversationId: string): Promise<Call | null> {
        return request<DataResponse<Call | null>>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/call`
        ).then((response) => response.data);
      },

    startCall(conversationId: string, mediaKind: CallMediaKind): Promise<CallSessionResponse> {
        return request<CallSessionResponse>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls`,
          { method: "POST", body: JSON.stringify({ media_kind: mediaKind }) }
        );
      },

    joinCall(conversationId: string, callId: string): Promise<CallSessionResponse> {
        return request<CallSessionResponse>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls/${encodeURIComponent(callId)}/join`,
          { method: "POST" }
        );
      },

    endCall(conversationId: string, callId: string): Promise<Call> {
        return request<DataResponse<Call>>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls/${encodeURIComponent(callId)}/end`,
          { method: "POST" }
        ).then((response) => response.data);
      },

    callParticipants(conversationId: string, callId: string): Promise<CallParticipantState[]> {
        return request<ListResponse<CallParticipantState>>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls/${encodeURIComponent(callId)}/participants`
        ).then((response) => response.data);
      },

    muteCallParticipant(conversationId: string, callId: string, providerIdentity: string, trackSid: string): Promise<void> {
        return request(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls/${encodeURIComponent(callId)}/participants/mute`,
          { method: "POST", body: JSON.stringify({ provider_identity: providerIdentity, track_sid: trackSid }) }
        );
      },

    removeCallParticipant(conversationId: string, callId: string, providerIdentity: string): Promise<void> {
        return request(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/calls/${encodeURIComponent(callId)}/participants/remove`,
          { method: "POST", body: JSON.stringify({ provider_identity: providerIdentity }) }
        );
      }
  };
  return {
    ...api,
    audioCall(conversationId: string): Promise<Call | null> {
      return api.call(conversationId);
    },
    startAudioCall(conversationId: string): Promise<CallSessionResponse> {
      return api.startCall(conversationId, "audio");
    },
    joinAudioCall(conversationId: string, callId: string): Promise<CallSessionResponse> {
      return api.joinCall(conversationId, callId);
    },
    endAudioCall(conversationId: string, callId: string): Promise<Call> {
      return api.endCall(conversationId, callId);
    }
  };
}

export type CallsApi = ReturnType<typeof createCallsApi>;
