export interface DocumentAtom { id: string; after_id: string | null; text: string; deleted: boolean; order: number }
export interface SharedDocument { id: string; conversation_id: string; title: string; content: string; generation: number; version: number; updated_at: string; atoms: DocumentAtom[]; readonly: boolean }
export interface DocumentChange { after_id: string | null; delete_ids: string[]; insert: string }
export interface DocumentEdit { client_operation_id: string; generation: number; base_version: number; kind: "edit" | "rename"; changes?: DocumentChange[]; title?: string }
export interface DocumentOperation { document_id: string; conversation_id: string; client_operation_id: string; generation: number; version: number; kind: "create" | "copy" | "edit" | "rename"; title: string | null; inserted_atoms: DocumentAtom[]; deleted_atom_ids: string[]; inserted_at: string }
export interface DocumentReplay { data: DocumentOperation[]; page: { generation: number; through_version: number; next_after_version: number; has_more: boolean } }
export interface DocumentPresence { user_id: string; device_id: string; generation: number; anchor_id: string | null; head_id: string | null }

export type DocumentSummary = Pick<SharedDocument, "id" | "conversation_id" | "title" | "generation" | "version" | "updated_at" | "readonly"> & { excerpt: string };
