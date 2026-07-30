import type { Attachment, AttachmentDownloadResponse, AttachmentIntentResponse, AttachmentSafety, AttachmentThumbnailIntent, DataResponse, FilesPageResponse, FilesQueryOptions, ListResponse } from "../../types";
import type { ApiRequest } from "../contracts";

interface FilesApiSupport {
  attachmentContentType: (file: File | Blob) => string;
}

export function createFilesApi(request: ApiRequest, { attachmentContentType }: FilesApiSupport) {
  const api = {
    files(options: FilesQueryOptions = {}): Promise<FilesPageResponse> {
        const query = new URLSearchParams({
          scope: options.scope ?? "recent",
          limit: String(Math.max(1, Math.min(options.limit ?? 25, 100)))
        });
        if (options.conversation_id) query.set("conversation_id", options.conversation_id);
        if (options.cursor) query.set("cursor", options.cursor);
        return request(`/api/v1/files?${query.toString()}`);
      },

    attachmentSafety(): Promise<AttachmentSafety[]> {
        return request<ListResponse<AttachmentSafety>>("/api/v1/admin/attachment-safety").then(
          (response) => response.data
        );
      },

    retryAttachmentScan(id: string): Promise<AttachmentSafety> {
        return request<DataResponse<AttachmentSafety>>(`/api/v1/admin/attachment-safety/${encodeURIComponent(id)}/retry`, { method: "POST" }).then(
          (response) => response.data
        );
      },

    createAttachment(
        file: File,
        checksum: string,
        signal?: AbortSignal,
        thumbnail?: AttachmentThumbnailIntent
      ): Promise<AttachmentIntentResponse> {
        return request("/api/v1/attachments", {
          method: "POST",
          signal,
          body: JSON.stringify({
            file_name: file.name,
            content_type: attachmentContentType(file),
            byte_size: file.size,
            checksum_sha256: checksum,
            ...(thumbnail ? { thumbnail } : {})
          })
        });
      },

    completeAttachment(id: string, signal?: AbortSignal): Promise<Attachment> {
        return request<DataResponse<Attachment>>(
          `/api/v1/attachments/${encodeURIComponent(id)}/complete`,
          { method: "POST", signal }
        ).then((response) => response.data);
      },

    abandonAttachment(id: string): Promise<void> {
        return request(`/api/v1/attachments/${encodeURIComponent(id)}`, {
          method: "DELETE"
        });
      },

    attachmentDownload(id: string): Promise<AttachmentDownloadResponse> {
        return request(`/api/v1/attachments/${encodeURIComponent(id)}`);
      },

    attachmentStatus(
        id: string,
        signal?: AbortSignal
      ): Promise<AttachmentDownloadResponse> {
        return request(`/api/v1/attachments/${encodeURIComponent(id)}`, { signal });
      }
  };
  return api;
}

export type FilesApi = ReturnType<typeof createFilesApi>;
