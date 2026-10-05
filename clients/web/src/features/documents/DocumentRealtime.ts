import { Socket, type Channel } from "phoenix";
import type { DocumentOperation, DocumentPresence } from "../../types/sharedDocuments";
interface DynamicSocket extends Socket { channel(topic: string, params: Record<string, unknown>): Channel }
export class DocumentRealtime {
  private socket: Socket;
  private channel: Channel;
  private stopped = false;
  constructor(endpoint: string, ticket: string, documentId: string, callbacks: { operation: (value: DocumentOperation) => void; presence: (value: DocumentPresence) => void; closed: () => void }) {
    this.socket = new Socket(endpoint, { params: { socket_ticket: ticket }, reconnectAfterMs: () => 60_000 });
    this.channel = (this.socket as DynamicSocket).channel(`document:${documentId}`, {});
    this.channel.on("document.operation_applied.v1", (value: unknown) => {
      if (!this.stopped && value && typeof value === "object") {
        const operation = value as DocumentOperation;
        if (operation.document_id === documentId && Number.isSafeInteger(operation.version) && operation.version > 0 && Array.isArray(operation.inserted_atoms) && Array.isArray(operation.deleted_atom_ids)) callbacks.operation(operation);
      }
    });
    this.channel.on("document.presence.v1", (value: unknown) => {
      if (!this.stopped && value && typeof value === "object") {
        const presence = value as DocumentPresence;
        if (typeof presence.user_id === "string" && typeof presence.device_id === "string" && Number.isSafeInteger(presence.generation) &&
          (presence.anchor_id === null || typeof presence.anchor_id === "string") && (presence.head_id === null || typeof presence.head_id === "string")) callbacks.presence(presence);
      }
    });
    const close = () => { if (!this.stopped) { this.disconnect(); callbacks.closed(); } };
    this.socket.onClose(close); this.socket.onError(close); this.channel.onError(close);
  }
  connect(): Promise<void> {
    this.socket.connect();
    return new Promise((resolve, reject) => this.channel.join().receive("ok", () => resolve()).receive("error", () => reject(new Error("Document access changed"))).receive("timeout", () => reject(new Error("Document connection timed out"))));
  }
  presence(value: { generation: number; anchor_id: string | null; head_id: string | null }) { if (!this.stopped) this.channel.push("document.presence.v1", value); }
  disconnect() { this.stopped = true; this.channel.leave(); this.socket.disconnect(); }
}
