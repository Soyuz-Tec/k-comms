import type { ApiRequest } from "../contracts";
import type { BoardAsset, BoardAssetDownload, BoardExport, BoardSummary, BoardVersion, SavedItemsPage, SynchronizedDraft, UnifiedResultKind, UnifiedSearchPage } from "../../types/rich-content";
import type { DataResponse } from "../../types";

export function createRichContentApi(request: ApiRequest) {
  const boardPath = (conversationId: string) => `/api/v1/conversations/${encodeURIComponent(conversationId)}/whiteboard`;
  return {
    boardGallery(q = ""): Promise<{ data: BoardSummary[]; page: { truncated: boolean } }> { return request(`/api/v1/whiteboards?q=${encodeURIComponent(q)}`); },
    renameBoard(conversationId: string, title: string, expectedVersion: number): Promise<BoardSummary> {
      return request<DataResponse<BoardSummary>>(`${boardPath(conversationId)}/title`, { method: "PUT", body: JSON.stringify({ title, expected_version: expectedVersion }) }).then(r => r.data);
    },
    boardVersions(conversationId: string): Promise<BoardVersion[]> { return request<DataResponse<BoardVersion[]>>(`${boardPath(conversationId)}/versions`).then(r => r.data); },
    checkpointBoard(conversationId: string, label: string, expectedSequence: number): Promise<BoardVersion> {
      return request<DataResponse<BoardVersion>>(`${boardPath(conversationId)}/versions`, { method: "POST", body: JSON.stringify({ label, expected_sequence: expectedSequence }) }).then(r => r.data);
    },
    restoreBoard(conversationId: string, versionId: string, expectedSequence: number): Promise<BoardSummary> {
      return request<DataResponse<BoardSummary>>(`${boardPath(conversationId)}/versions/${encodeURIComponent(versionId)}/restore`, { method: "POST", body: JSON.stringify({ expected_sequence: expectedSequence }) }).then(r => r.data);
    },
    exportBoard(conversationId: string): Promise<BoardExport> { return request<DataResponse<BoardExport>>(`${boardPath(conversationId)}/export`).then(r => r.data); },
    addBoardAsset(conversationId: string, attachmentId: string): Promise<BoardAsset> {
      return request<DataResponse<BoardAsset>>(`${boardPath(conversationId)}/assets`, { method: "POST", body: JSON.stringify({ attachment_id: attachmentId }) }).then(r => r.data);
    },
    boardAsset(conversationId: string, assetId: string): Promise<BoardAssetDownload> { return request(`${boardPath(conversationId)}/assets/${encodeURIComponent(assetId)}`); },
    savedItems(cursor?: string | null): Promise<SavedItemsPage> { return request(`/api/v1/saved-items${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`); },
    saveMessage(messageId: string): Promise<void> { return request(`/api/v1/saved-items/${encodeURIComponent(messageId)}`, { method: "PUT" }); },
    unsaveMessage(messageId: string): Promise<void> { return request(`/api/v1/saved-items/${encodeURIComponent(messageId)}`, { method: "DELETE" }); },
    messageDraft(conversationId: string, threadKey = "main"): Promise<SynchronizedDraft> {
      return request<DataResponse<SynchronizedDraft>>(`/api/v1/conversations/${encodeURIComponent(conversationId)}/draft?thread_key=${encodeURIComponent(threadKey)}`).then(r => r.data);
    },
    updateMessageDraft(conversationId: string, body: string, expectedVersion: number, threadKey = "main"): Promise<SynchronizedDraft> {
      return request<DataResponse<SynchronizedDraft>>(`/api/v1/conversations/${encodeURIComponent(conversationId)}/draft`, { method: "PUT", body: JSON.stringify({ body, expected_version: expectedVersion, thread_key: threadKey }) }).then(r => r.data);
    },
    unifiedSearch(q: string, options: { kind?: UnifiedResultKind | "all"; conversation_id?: string; after?: string; before?: string; cursor?: string | null; limit?: number } = {}): Promise<UnifiedSearchPage> {
      const params = new URLSearchParams({ q });
      for (const [key, value] of Object.entries(options)) if (value !== undefined && value !== null) params.set(key, String(value));
      return request(`/api/v1/search/unified?${params.toString()}`);
    }
  };
}
export type RichContentApi = ReturnType<typeof createRichContentApi>;
