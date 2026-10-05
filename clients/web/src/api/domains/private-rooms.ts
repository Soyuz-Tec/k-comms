import type { ApiRequest } from "../contracts";
import type { PrivateRoomApi, PrivateRoom, MatrixClientSession, OpaqueContent, OpaqueEvent, PendingPrivateIntent } from "../../features/private-rooms/types";
export function createPrivateRoomApi(request: ApiRequest): PrivateRoomApi {
  const data = async <T>(path: string, options = {}): Promise<T> => (await request<{ data: T }>(path, options)).data;
  return {
    matrixClientSession: () => data<MatrixClientSession>("/api/v1/me/matrix/session", { method: "POST" }),
    matrixUploadPublicSigningKeys: (keys) => request<void>("/api/v1/me/matrix/public-signing-keys", { method: "POST", body: JSON.stringify(keys) }),
    privateRooms: () => data<PrivateRoom[]>("/api/v1/private-rooms"),
    privateRoom: (id) => data<PrivateRoom>(`/api/v1/private-rooms/${encodeURIComponent(id)}`),
    createPrivateRoom: (input) => data<PrivateRoom>("/api/v1/private-rooms", { method: "POST", body: JSON.stringify(input) }),
    removePrivateMember: (id, user, membership_epoch) => data<PrivateRoom>(`/api/v1/private-rooms/${encodeURIComponent(id)}/members/${encodeURIComponent(user)}`, { method: "DELETE", body: JSON.stringify({ membership_epoch }) }),
    sendPrivateEvent: (id, transaction_id, content: OpaqueContent, membership_epoch, generation) => data<{ event: OpaqueEvent; replayed: boolean }>(`/api/v1/private-rooms/${encodeURIComponent(id)}/events`, { method: "POST", body: JSON.stringify({ transaction_id, content, membership_epoch, generation }) }),
    replayPrivateEvents: (id, after_sequence, membership_epoch, generation) => data<{ events: OpaqueEvent[]; pending_intents: PendingPrivateIntent[]; has_more: boolean; generation: number; membership_epoch: number }>(`/api/v1/private-rooms/${encodeURIComponent(id)}/events?${new URLSearchParams({ after_sequence: String(after_sequence), membership_epoch: String(membership_epoch), generation: String(generation) })}`)
  };
}
