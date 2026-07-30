import { useCallback, useEffect, useRef, useState } from "react";
import type { ChangeEvent } from "react";
import type { ApiClient } from "../../api";
import {
  downloadUrl,
  sha256,
  sha256Blob,
  uploadToPresignedTarget
} from "../../api";
import { generateThumbnail } from "../../lib/thumbnail";
import { clientMessageId, errorText } from "../../lib/format";
import type { Attachment, UserCapabilities } from "../../types";
import {
  attachmentUploadBusy,
  attachmentUploadReady,
  type PendingAttachmentUpload
} from "./AttachmentUploadList";
import {
  abortableDelay,
  attachmentCancelled,
  delay,
  formatAttachmentLimit
} from "./chatSupport";

interface UseChatAttachmentsOptions {
  api: ApiClient;
  capabilities: UserCapabilities | null;
  setError: (error: string | null) => void;
}

export interface AttachmentSendReservation {
  fail: (abandonOrphans: boolean) => void;
  succeed: () => void;
}

export function useChatAttachments({
  api,
  capabilities,
  setError
}: UseChatAttachmentsOptions) {
  const [pendingAttachments, setPendingAttachments] = useState<
    PendingAttachmentUpload[]
  >([]);
  const cancelledUploadsRef = useRef(new Set<string>());
  const uploadControllersRef = useRef(new Map<string, AbortController>());
  const intentIdsRef = useRef(new Map<string, string>());
  const sendingIdsRef = useRef(new Set<string>());
  const abandonRequestsRef = useRef(new Map<string, Promise<void>>());
  const mountedRef = useRef(true);

  const abandonAttachmentId = useCallback(
    (id: string): Promise<void> => {
      const existing = abandonRequestsRef.current.get(id);
      if (existing) return existing;

      const request = (async () => {
        let lastReason: unknown = new Error(
          "The attachment could not be removed"
        );
        for (let attempt = 0; attempt < 3; attempt += 1) {
          try {
            await api.abandonAttachment(id);
            return;
          } catch (reason: unknown) {
            lastReason = reason;
            if (attempt < 2) await delay(250 * (attempt + 1));
          }
        }
        throw lastReason;
      })().finally(() => {
        abandonRequestsRef.current.delete(id);
      });

      abandonRequestsRef.current.set(id, request);
      return request;
    },
    [api]
  );

  const abandonClientAttachment = useCallback(
    async (clientId: string): Promise<void> => {
      const id = intentIdsRef.current.get(clientId);
      if (!id) return;
      await abandonAttachmentId(id);
      if (intentIdsRef.current.get(clientId) === id) {
        intentIdsRef.current.delete(clientId);
      }
    },
    [abandonAttachmentId]
  );

  const abandonClientAttachmentInBackground = useCallback(
    (clientId: string) => {
      void abandonClientAttachment(clientId).catch(() => {
        if (mountedRef.current) {
          setError(
            "A cancelled file is still awaiting secure cleanup. The server will keep retrying automatically."
          );
        }
      });
    },
    [abandonClientAttachment, setError]
  );

  const cancelAll = useCallback(() => {
    for (const [clientId, controller] of uploadControllersRef.current) {
      cancelledUploadsRef.current.add(clientId);
      controller.abort();
    }
    uploadControllersRef.current.clear();
    for (const [clientId, attachmentId] of intentIdsRef.current) {
      if (sendingIdsRef.current.has(attachmentId)) continue;
      cancelledUploadsRef.current.add(clientId);
      abandonClientAttachmentInBackground(clientId);
    }
  }, [abandonClientAttachmentInBackground]);

  const reset = useCallback(() => {
    cancelAll();
    setPendingAttachments([]);
  }, [cancelAll]);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  useEffect(() => () => cancelAll(), [cancelAll]);

  const updatePendingAttachment = useCallback(
    (
      clientId: string,
      update: Partial<
        Pick<
          PendingAttachmentUpload,
          "attachment" | "phase" | "error" | "cancelRequested" | "progress"
        >
      >
    ) => {
      setPendingAttachments((current) =>
        current.map((item) =>
          item.clientId === clientId ? { ...item, ...update } : item
        )
      );
    },
    []
  );

  const monitorAttachment = useCallback(
    async (
      clientId: string,
      id: string,
      controller: AbortController
    ) => {
      try {
        for (let attempt = 0; attempt < 45; attempt += 1) {
          await abortableDelay(1_000, controller.signal);
          if (cancelledUploadsRef.current.has(clientId)) return;
          try {
            const response = await api.attachmentStatus(id, controller.signal);
            const attachment = response.data;
            if (cancelledUploadsRef.current.has(clientId)) return;
            if (attachment.status === "ready") {
              updatePendingAttachment(clientId, {
                attachment,
                phase: "ready",
                error: undefined
              });
              return;
            }
            if (
              ["quarantined", "scan_failed", "deleted"].includes(
                attachment.status
              )
            ) {
              const message = `${attachment.file_name} could not be attached: ${attachment.status.replace("_", " ")}.`;
              updatePendingAttachment(clientId, {
                attachment,
                phase: "blocked",
                error: message
              });
              setError(message);
              return;
            }
          } catch (reason: unknown) {
            if (controller.signal.aborted) return;
            if (attempt === 44) {
              const message = errorText(reason);
              updatePendingAttachment(clientId, {
                phase: "scan_delayed",
                error: message
              });
              setError(message);
              return;
            }
          }
        }
        const message =
          "Attachment scanning is taking longer than expected. You can remove the file and retry later.";
        updatePendingAttachment(clientId, {
          phase: "scan_delayed",
          error: message
        });
        setError(message);
      } finally {
        if (uploadControllersRef.current.get(clientId) === controller) {
          uploadControllersRef.current.delete(clientId);
        }
      }
    },
    [api, setError, updatePendingAttachment]
  );

  const processAttachment = useCallback(
    async (item: PendingAttachmentUpload) => {
      const { clientId, file } = item;
      uploadControllersRef.current.get(clientId)?.abort();
      const controller = new AbortController();
      uploadControllersRef.current.set(clientId, controller);
      cancelledUploadsRef.current.delete(clientId);
      let monitoring = false;
      try {
        const maxBytes = capabilities?.max_attachment_bytes;
        if (!maxBytes) {
          throw new Error(
            "The server did not provide an attachment size limit"
          );
        }
        if (file.size > maxBytes) {
          throw new Error(
            `${file.name} exceeds the ${formatAttachmentLimit(maxBytes)} limit`
          );
        }

        updatePendingAttachment(clientId, {
          phase: "hashing",
          error: undefined
        });
        const checksum = await sha256(file);
        if (cancelledUploadsRef.current.has(clientId)) return;

        const thumbnail = await generateThumbnail(file);
        if (cancelledUploadsRef.current.has(clientId)) return;
        const thumbnailChecksum = thumbnail
          ? await sha256Blob(thumbnail.blob)
          : null;
        if (cancelledUploadsRef.current.has(clientId)) return;

        updatePendingAttachment(clientId, { phase: "requesting" });
        // Intent creation deliberately finishes so a cancellation can abandon
        // the server row by its resolved ID instead of leaking pending state.
        const intent = await api.createAttachment(
          file,
          checksum,
          undefined,
          thumbnail && thumbnailChecksum
            ? {
                content_type: thumbnail.contentType,
                byte_size: thumbnail.byteSize,
                checksum_sha256: thumbnailChecksum
              }
            : undefined
        );
        intentIdsRef.current.set(clientId, intent.data.id);
        if (
          attachmentCancelled(
            clientId,
            controller,
            cancelledUploadsRef
          )
        ) {
          abandonClientAttachmentInBackground(clientId);
          return;
        }

        updatePendingAttachment(clientId, {
          attachment: intent.data,
          phase: "uploading",
          progress: 0
        });
        await uploadToPresignedTarget(
          intent.upload,
          file,
          controller.signal,
          (fraction) => {
            if (cancelledUploadsRef.current.has(clientId)) return;
            updatePendingAttachment(clientId, { progress: fraction });
          }
        );
        if (
          attachmentCancelled(
            clientId,
            controller,
            cancelledUploadsRef
          )
        ) {
          abandonClientAttachmentInBackground(clientId);
          return;
        }

        // A thumbnail is an optional enhancement and never blocks completion.
        if (thumbnail && intent.thumbnail_upload) {
          try {
            await uploadToPresignedTarget(
              intent.thumbnail_upload,
              thumbnail.blob,
              controller.signal
            );
          } catch {
            if (
              attachmentCancelled(
                clientId,
                controller,
                cancelledUploadsRef
              )
            ) {
              abandonClientAttachmentInBackground(clientId);
              return;
            }
          }
        }

        updatePendingAttachment(clientId, {
          phase: "finalizing",
          progress: undefined
        });
        const attachment = await api.completeAttachment(
          intent.data.id,
          controller.signal
        );
        if (
          attachmentCancelled(
            clientId,
            controller,
            cancelledUploadsRef
          )
        ) {
          abandonClientAttachmentInBackground(clientId);
          return;
        }

        if (attachment.status === "ready") {
          updatePendingAttachment(clientId, {
            attachment,
            phase: "ready"
          });
          return;
        }
        if (
          ["quarantined", "scan_failed", "deleted"].includes(
            attachment.status
          )
        ) {
          const message = `${attachment.file_name} could not be attached: ${attachment.status.replace("_", " ")}.`;
          updatePendingAttachment(clientId, {
            attachment,
            phase: "blocked",
            error: message
          });
          setError(message);
          return;
        }
        updatePendingAttachment(clientId, {
          attachment,
          phase: "scanning"
        });
        monitoring = true;
        void monitorAttachment(clientId, attachment.id, controller);
      } catch (reason: unknown) {
        if (
          attachmentCancelled(
            clientId,
            controller,
            cancelledUploadsRef
          )
        ) {
          abandonClientAttachmentInBackground(clientId);
          return;
        }
        const message = errorText(reason);
        updatePendingAttachment(clientId, {
          phase: "retryable_error",
          error: message
        });
        setError(message);
      } finally {
        if (
          !monitoring &&
          uploadControllersRef.current.get(clientId) === controller
        ) {
          uploadControllersRef.current.delete(clientId);
        }
      }
    },
    [
      abandonClientAttachmentInBackground,
      api,
      capabilities?.max_attachment_bytes,
      monitorAttachment,
      setError,
      updatePendingAttachment
    ]
  );

  const filesSelected = useCallback(
    async (event: ChangeEvent<HTMLInputElement>) => {
      const selected = [...(event.target.files || [])];
      event.target.value = "";
      if (selected.length === 0) return;
      setError(null);
      const queued = selected.map((file) => ({
        clientId: clientMessageId(),
        file,
        localName: file.name,
        phase: "hashing" as const
      }));
      setPendingAttachments((current) => [...current, ...queued]);
      await Promise.all(queued.map((item) => processAttachment(item)));
    },
    [processAttachment, setError]
  );

  const cancelAttachment = useCallback(
    async (clientId: string) => {
      cancelledUploadsRef.current.add(clientId);
      uploadControllersRef.current.get(clientId)?.abort();
      uploadControllersRef.current.delete(clientId);
      if (!intentIdsRef.current.has(clientId)) {
        setPendingAttachments((current) =>
          current.filter((item) => item.clientId !== clientId)
        );
        return;
      }

      updatePendingAttachment(clientId, {
        phase: "cancelling",
        error: undefined,
        cancelRequested: true
      });

      try {
        await abandonClientAttachment(clientId);
        setPendingAttachments((current) =>
          current.filter((item) => item.clientId !== clientId)
        );
      } catch {
        const message =
          "The file could not be removed yet. Retry, or leave it for automatic server cleanup.";
        updatePendingAttachment(clientId, {
          phase: "retryable_error",
          error: message,
          cancelRequested: true
        });
        setError(message);
      }
    },
    [abandonClientAttachment, setError, updatePendingAttachment]
  );

  const retryAttachment = useCallback(
    async (clientId: string) => {
      const item = pendingAttachments.find(
        (candidate) => candidate.clientId === clientId
      );
      if (!item || item.phase !== "retryable_error") return;
      if (item.cancelRequested) {
        await cancelAttachment(clientId);
        return;
      }

      uploadControllersRef.current.get(clientId)?.abort();
      updatePendingAttachment(clientId, {
        phase: "cancelling",
        error: undefined
      });

      try {
        await abandonClientAttachment(clientId);
      } catch {
        const message =
          "The previous secure upload could not be removed. Retry before creating a replacement.";
        updatePendingAttachment(clientId, {
          phase: "retryable_error",
          error: message,
          cancelRequested: false
        });
        setError(message);
        return;
      }

      if (cancelledUploadsRef.current.has(clientId)) return;
      void processAttachment({
        ...item,
        attachment: undefined,
        phase: "hashing",
        error: undefined,
        cancelRequested: false
      });
    },
    [
      abandonClientAttachment,
      cancelAttachment,
      pendingAttachments,
      processAttachment,
      setError,
      updatePendingAttachment
    ]
  );

  const reserveForSend = useCallback(
    (ids: string[]): AttachmentSendReservation => {
      const attachmentIds = new Set(ids);
      const originEntries = [...intentIdsRef.current].filter(
        ([, attachmentId]) => attachmentIds.has(attachmentId)
      );
      for (const attachmentId of attachmentIds) {
        sendingIdsRef.current.add(attachmentId);
      }
      let settled = false;

      return {
        fail(abandonOrphans: boolean) {
          if (settled) return;
          settled = true;
          for (const attachmentId of attachmentIds) {
            sendingIdsRef.current.delete(attachmentId);
          }
          if (abandonOrphans) {
            for (const [clientId] of originEntries) {
              abandonClientAttachmentInBackground(clientId);
            }
          }
        },
        succeed() {
          if (settled) return;
          settled = true;
          for (const attachmentId of attachmentIds) {
            sendingIdsRef.current.delete(attachmentId);
          }
          for (const [clientId, attachmentId] of originEntries) {
            if (intentIdsRef.current.get(clientId) === attachmentId) {
              intentIdsRef.current.delete(clientId);
            }
          }
        }
      };
    },
    [abandonClientAttachmentInBackground]
  );

  const openAttachment = useCallback(
    async (attachment: Attachment) => {
      if (attachment.status !== "ready") {
        setError(
          "This attachment is not available until its safety scan passes."
        );
        return;
      }
      setError(null);
      try {
        const response = await api.attachmentDownload(attachment.id);
        const url = downloadUrl(response.download);
        if (!url) {
          throw new Error(
            "The server did not return an approved HTTPS download URL"
          );
        }
        window.open(url, "_blank", "noopener,noreferrer");
      } catch (reason: unknown) {
        setError(errorText(reason));
      }
    },
    [api, setError]
  );

  const requestThumbnail = useCallback(
    async (attachmentId: string): Promise<string | null> => {
      try {
        const response = await api.attachmentDownload(attachmentId);
        return downloadUrl(response.thumbnail_download);
      } catch {
        return null;
      }
    },
    [api]
  );

  const clearPending = useCallback(() => setPendingAttachments([]), []);
  const uploading = pendingAttachments.some(attachmentUploadBusy);
  const ready = pendingAttachments.every(attachmentUploadReady);
  const readyAttachmentIds = pendingAttachments.flatMap(({ attachment }) =>
    attachment ? [attachment.id] : []
  );

  return {
    pendingAttachments,
    uploading,
    ready,
    readyAttachmentIds,
    filesSelected,
    cancelAttachment,
    retryAttachment,
    reset,
    clearPending,
    reserveForSend,
    openAttachment,
    requestThumbnail
  };
}
