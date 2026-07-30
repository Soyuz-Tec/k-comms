import {
  useCallback,
  useEffect,
  useRef,
  useState
} from "react";
import type {
  ChangeEvent,
  MutableRefObject
} from "react";
import {
  downloadUrl,
  sha256,
  uploadToPresignedTarget
} from "../../api";
import type { ApiClient } from "../../api";
import { errorText } from "../../lib/format";
import type { Attachment } from "../../types";

export interface PendingThreadAttachment {
  attachment: Attachment;
  localName: string;
}

export function useThreadAttachments({
  activeThreadKeyRef,
  api,
  conversationId,
  maxAttachmentBytes,
  requestGenerationRef,
  setError,
  targetMessageId
}: {
  activeThreadKeyRef: MutableRefObject<string>;
  api: ApiClient;
  conversationId: string;
  maxAttachmentBytes?: number;
  requestGenerationRef: MutableRefObject<number>;
  setError: (error: string | null) => void;
  targetMessageId: string;
}) {
  const [uploading, setUploading] = useState(false);
  const [pendingAttachments, setPendingAttachments] = useState<
    PendingThreadAttachment[]
  >([]);
  const pendingAttachmentIdsRef = useRef(new Set<string>());
  const sendingAttachmentIdsRef = useRef(new Set<string>());

  const abandonPending = useCallback(() => {
    for (const id of pendingAttachmentIdsRef.current) {
      if (sendingAttachmentIdsRef.current.has(id)) continue;
      pendingAttachmentIdsRef.current.delete(id);
      void api.abandonAttachment(id).catch(() => undefined);
    }
  }, [api]);

  useEffect(() => abandonPending, [
    abandonPending,
    conversationId,
    targetMessageId
  ]);

  const reset = useCallback(() => {
    setPendingAttachments([]);
    setUploading(false);
  }, []);

  const clearPending = useCallback(() => {
    setPendingAttachments([]);
  }, []);

  const reserveForSend = useCallback(
    (
      attachmentIds: string[],
      threadKey: string,
      requestGeneration: number
    ) => {
      const ids = new Set(attachmentIds);
      for (const id of ids) sendingAttachmentIdsRef.current.add(id);

      return {
        fail(abandonOrphans: boolean) {
          for (const id of ids) {
            sendingAttachmentIdsRef.current.delete(id);
            if (!abandonOrphans) continue;
            pendingAttachmentIdsRef.current.delete(id);
            void api.abandonAttachment(id).catch(() => undefined);
          }
        },
        succeed() {
          for (const id of ids) {
            sendingAttachmentIdsRef.current.delete(id);
            pendingAttachmentIdsRef.current.delete(id);
          }
        },
        stale() {
          return (
            activeThreadKeyRef.current !== threadKey ||
            requestGenerationRef.current !== requestGeneration
          );
        }
      };
    },
    [activeThreadKeyRef, api, requestGenerationRef]
  );

  const monitorAttachment = useCallback(
    async (
      id: string,
      threadKey: string,
      requestGeneration: number
    ) => {
      for (let attempt = 0; attempt < 45; attempt += 1) {
        await delay(1_000);
        if (
          activeThreadKeyRef.current !== threadKey ||
          requestGenerationRef.current !== requestGeneration
        ) {
          return;
        }
        try {
          const response = await api.attachmentStatus(id);
          if (
            activeThreadKeyRef.current !== threadKey ||
            requestGenerationRef.current !== requestGeneration
          ) {
            return;
          }
          const attachment = response.data;
          setPendingAttachments((current) =>
            current.map((item) =>
              item.attachment.id === id ? { ...item, attachment } : item
            )
          );
          if (attachment.status === "ready") return;
          if (
            ["quarantined", "scan_failed", "deleted"].includes(
              attachment.status
            )
          ) {
            setError(
              `${attachment.file_name} could not be attached: ${attachment.status.replace(
                "_",
                " "
              )}.`
            );
            return;
          }
        } catch (reason: unknown) {
          if (
            attempt === 44 &&
            activeThreadKeyRef.current === threadKey &&
            requestGenerationRef.current === requestGeneration
          ) {
            setError(errorText(reason));
          }
        }
      }
      if (
        activeThreadKeyRef.current === threadKey &&
        requestGenerationRef.current === requestGeneration
      ) {
        setError(
          "Attachment scanning is taking longer than expected. You can remove the file and retry later."
        );
      }
    },
    [activeThreadKeyRef, api, requestGenerationRef, setError]
  );

  const filesSelected = useCallback(
    async (event: ChangeEvent<HTMLInputElement>) => {
      const selected = [...(event.target.files || [])];
      event.target.value = "";
      if (selected.length === 0) return;
      const threadKey = activeThreadKeyRef.current;
      const requestGeneration = requestGenerationRef.current;
      setUploading(true);
      setError(null);
      try {
        for (const file of selected) {
          if (!maxAttachmentBytes) {
            throw new Error(
              "The server did not provide an attachment size limit"
            );
          }
          if (file.size > maxAttachmentBytes) {
            throw new Error(
              `${file.name} exceeds the ${formatAttachmentLimit(
                maxAttachmentBytes
              )} limit`
            );
          }
          const intent = await api.createAttachment(file, await sha256(file));
          if (
            activeThreadKeyRef.current !== threadKey ||
            requestGenerationRef.current !== requestGeneration
          ) {
            await api.abandonAttachment(intent.data.id).catch(() => undefined);
            return;
          }
          await uploadToPresignedTarget(intent.upload, file);
          if (
            activeThreadKeyRef.current !== threadKey ||
            requestGenerationRef.current !== requestGeneration
          ) {
            await api.abandonAttachment(intent.data.id).catch(() => undefined);
            return;
          }
          const attachment = await api.completeAttachment(intent.data.id);
          pendingAttachmentIdsRef.current.add(attachment.id);
          if (
            activeThreadKeyRef.current !== threadKey ||
            requestGenerationRef.current !== requestGeneration
          ) {
            pendingAttachmentIdsRef.current.delete(intent.data.id);
            await api.abandonAttachment(intent.data.id).catch(() => undefined);
            return;
          }
          setPendingAttachments((current) => [
            ...current,
            { attachment, localName: file.name }
          ]);
          if (attachment.status !== "ready") {
            void monitorAttachment(
              attachment.id,
              threadKey,
              requestGeneration
            );
          }
        }
      } catch (reason: unknown) {
        if (
          activeThreadKeyRef.current === threadKey &&
          requestGenerationRef.current === requestGeneration
        ) {
          setError(errorText(reason));
        }
      } finally {
        if (
          activeThreadKeyRef.current === threadKey &&
          requestGenerationRef.current === requestGeneration
        ) {
          setUploading(false);
        }
      }
    },
    [
      activeThreadKeyRef,
      api,
      maxAttachmentBytes,
      monitorAttachment,
      requestGenerationRef,
      setError
    ]
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

  const removePendingAttachment = useCallback(
    (attachment: Attachment) => {
      pendingAttachmentIdsRef.current.delete(attachment.id);
      setPendingAttachments((current) =>
        current.filter((item) => item.attachment.id !== attachment.id)
      );
      void api.abandonAttachment(attachment.id).catch(() => {
        if (
          activeThreadKeyRef.current ===
          `${conversationId}:${targetMessageId}`
        ) {
          setError("The removed file is still awaiting secure cleanup.");
        }
      });
    },
    [
      activeThreadKeyRef,
      api,
      conversationId,
      setError,
      targetMessageId
    ]
  );

  const attachmentsReady = pendingAttachments.every(
    ({ attachment }) => attachment.status === "ready"
  );
  const attachmentAnnouncement = pendingAttachments
    .map(
      ({ attachment, localName }) =>
        `${localName}: ${attachmentLabel(attachment)}`
    )
    .join(". ");

  return {
    attachmentAnnouncement,
    attachmentsReady,
    clearPending,
    filesSelected,
    openAttachment,
    pendingAttachments,
    removePendingAttachment,
    reserveForSend,
    reset,
    uploading
  };
}

export function attachmentLabel(attachment: Attachment): string {
  if (attachment.status === "ready") return "Safety scan passed";
  if (attachment.status === "quarantined") return "Quarantined";
  if (attachment.status === "scan_failed") return "Scan failed";
  if (attachment.status === "deleted") return "Deleted";
  return "Safety scan pending";
}

function formatAttachmentLimit(value: number): string {
  return value >= 1_000_000
    ? `${(value / 1_000_000).toFixed(
        value % 1_000_000 === 0 ? 0 : 1
      )} MB`
    : `${Math.ceil(value / 1_000)} KB`;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}
