export interface MatrixIdentity { tenant_id: string; user_id: string; issuer: string; matrix_user_id: string; provisioning_state: "ready" }
export interface MatrixClientSession { homeserver_url: string; matrix_user_id: string; matrix_device_id: string; access_token: string; expires_at: string; k_session_id: string; control_matrix_user_id: string }
export interface PrivateRoom { id: string; tenant_id: string; title: string; matrix_room_id: string | null; control_matrix_user_id: string; state: "provisioning" | "active" | "rekey_pending"; membership_epoch: number; generation: number; role: "owner" | "member"; members: MatrixIdentity[] }
export interface OpaqueContent { algorithm: "m.megolm.v1.aes-sha2"; ciphertext: string; session_id: string; device_id?: string; sender_key?: string }
export interface OpaqueEvent { id: string; conversation_id: string; sequence: number; matrix_event_id: string | null; matrix_room_id: string; matrix_sender: string; author_user_id: string; membership_epoch: number; generation: number; content: OpaqueContent | null; state: "pending" | "retained" | "erased" }
export interface PendingPrivateIntent { transaction_id: string; content: OpaqueContent; membership_epoch: number; generation: number }
export interface PrivateRoomApi {
  matrixClientSession(): Promise<MatrixClientSession>;
  matrixUploadPublicSigningKeys(keys: Record<string, unknown>): Promise<void>;
  privateRooms(): Promise<PrivateRoom[]>;
  privateRoom(id: string): Promise<PrivateRoom>;
  createPrivateRoom(input: { id: string; title: string; member_ids: string[] }): Promise<PrivateRoom>;
  removePrivateMember(id: string, user: string, membershipEpoch: number): Promise<PrivateRoom>;
  sendPrivateEvent(id: string, transactionId: string, content: OpaqueContent, membershipEpoch: number, generation: number): Promise<{ event: OpaqueEvent; replayed: boolean }>;
  replayPrivateEvents(id: string, afterSequence: number, membershipEpoch: number, generation: number): Promise<{ events: OpaqueEvent[]; pending_intents: PendingPrivateIntent[]; has_more: boolean; generation: number; membership_epoch: number }>;
}
