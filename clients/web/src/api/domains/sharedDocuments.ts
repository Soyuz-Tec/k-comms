import type { ApiRequest } from "../contracts";
import type { DocumentEdit, DocumentOperation, DocumentSummary, DocumentReplay, SharedDocument } from "../../types/sharedDocuments";
export function createSharedDocumentsApi(request: ApiRequest) {
  const originalRequest = request;
  request = async <T>(path: string, options = {}): Promise<T> => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), 15_000);
    try { return await originalRequest<T>(path, { ...options, signal: controller.signal }); }
    finally { window.clearTimeout(timer); }
  };
  const unwrap = <T>(promise: Promise<{ data: T }>) => promise.then(value => value.data);
  return {
    list: (conversationId: string, query = "") => unwrap(request<{ data: DocumentSummary[] }>(`/api/v1/conversations/${encodeURIComponent(conversationId)}/documents?q=${encodeURIComponent(query)}`)),
    create: (conversationId: string, title: string, clientId: string) => unwrap(request<{ data: SharedDocument }>(`/api/v1/conversations/${encodeURIComponent(conversationId)}/documents`, { method: "POST", body: JSON.stringify({ title, client_document_id: clientId }) })),
    get: (id: string) => unwrap(request<{ data: SharedDocument }>(`/api/v1/documents/${encodeURIComponent(id)}`)),
    apply: (id: string, input: DocumentEdit) => unwrap(request<{ data: DocumentOperation }>(`/api/v1/documents/${encodeURIComponent(id)}/operations`, { method: "POST", body: JSON.stringify(input) })),
    copy: (id: string, title: string, clientId: string) => unwrap(request<{ data: SharedDocument }>(`/api/v1/documents/${encodeURIComponent(id)}/copies`, { method: "POST", body: JSON.stringify({ title, client_document_id: clientId }) })),
    replay: (id: string, generation: number, afterVersion: number) => request<DocumentReplay>(`/api/v1/documents/${encodeURIComponent(id)}/operations?generation=${generation}&after_version=${afterVersion}&limit=100`)
  };
}
export type SharedDocumentsApi = ReturnType<typeof createSharedDocumentsApi>;
