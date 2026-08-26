import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router";
import { downloadUrl } from "../../api";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { AppIcon } from "../../components/AppIcon";
import {
  errorText,
  formatBytes,
  formatDateTime
} from "../../lib/format";
import {
  conversationParticipantIdentifier,
  duplicateDirectConversationNames,
  duplicateParticipantNames,
  participantIdentifier
} from "../../lib/participantIdentity";
import type {
  Conversation,
  FileSafetyState,
  FileSummary,
  FilesScope,
  User
} from "../../types";
import "./FilesPage.css";

const pageSize = 25;
type FileCategory = "all" | "documents" | "images";

export function FilesPage() {
  const { api, session } = useSession();
  const { conversations, users } = useWorkspaceData();
  const [scope, setScope] = useState<FilesScope>("recent");
  const [category, setCategory] = useState<FileCategory>("all");
  const [conversationId, setConversationId] = useState("");
  const [files, setFiles] = useState<FileSummary[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [downloadError, setDownloadError] = useState<string | null>(null);
  const [downloadingId, setDownloadingId] = useState<string | null>(null);
  const requestGeneration = useRef(0);

  const loadFiles = useCallback(async (mode: "replace" | "append", cursor?: string | null) => {
    const generation = ++requestGeneration.current;
    if (mode === "replace") setLoading(true);
    else setLoadingMore(true);
    setError(null);

    try {
      const page = await api.files({
        scope,
        conversation_id: conversationId || undefined,
        limit: pageSize,
        cursor
      });
      if (generation !== requestGeneration.current) return;
      setFiles((current) => mode === "append" ? mergeFiles(current, page.data) : page.data);
      setNextCursor(page.page.next_cursor);
      setHasMore(page.page.has_more);
    } catch (reason: unknown) {
      if (generation !== requestGeneration.current) return;
      setError(errorText(reason));
    } finally {
      if (generation === requestGeneration.current) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [api, conversationId, scope]);

  useEffect(() => {
    setFiles([]);
    setNextCursor(null);
    setHasMore(false);
    void loadFiles("replace");
    return () => {
      requestGeneration.current += 1;
    };
  }, [loadFiles]);

  const conversationById = useMemo(
    () => new Map(conversations.map((conversation) => [conversation.id, conversation])),
    [conversations]
  );
  const userById = useMemo(
    () => new Map(users.map((user) => [user.id, user])),
    [users]
  );
  const duplicateDirectNames = useMemo(
    () => duplicateDirectConversationNames(conversations),
    [conversations]
  );
  const duplicateUserNames = useMemo(
    () => duplicateParticipantNames(users),
    [users]
  );
  const visibleFiles = useMemo(
    () => files.filter((file) => category === "all" || fileCategory(file) === category),
    [category, files]
  );
  if (!session) return null;

  async function openDownload(file: FileSummary) {
    if (!file.downloadable || file.safety_state !== "available") return;
    const downloadWindow = window.open("about:blank", "_blank");
    if (!downloadWindow) {
      setDownloadError("Your browser blocked the download window. Allow pop-ups for K-Comms and try again.");
      return;
    }
    downloadWindow.opener = null;
    setDownloadingId(file.id);
    setDownloadError(null);
    try {
      const response = await api.attachmentDownload(file.id);
      const url = downloadUrl(response.download);
      if (!url) throw new Error("The server did not return an approved HTTPS download URL");
      downloadWindow.location.replace(url);
    } catch (reason: unknown) {
      downloadWindow.close();
      setDownloadError(errorText(reason));
    } finally {
      setDownloadingId(null);
    }
  }

  return (
    <main className="page-shell files-page" id="main-content">
      <header className="page-heading files-page-heading">
        <div>
          <h1>Files</h1>
        </div>
        <button
          className="button ghost"
          type="button"
          disabled={loading}
          onClick={() => void loadFiles("replace")}
        >
          <AppIcon name="refresh" />
          {loading ? "Refreshing…" : "Refresh"}
        </button>
      </header>

      <section className="files-surface" aria-labelledby="files-list-heading">
        <div className="files-toolbar">
          <div className="files-toolbar-heading">
            <span className="eyebrow">Authorized index</span>
            <h2 id="files-list-heading">Shared files</h2>
          </div>
          <fieldset className="files-category-tabs">
            <legend className="sr-only">File type</legend>
            {([
              ["all", "All"],
              ["documents", "Documents"],
              ["images", "Images"]
            ] as const).map(([value, label]) => (
              <button
                type="button"
                key={value}
                aria-pressed={category === value}
                onClick={() => setCategory(value)}
              >
                {label}
              </button>
            ))}
          </fieldset>
          <details className="files-advanced-filter">
            <summary aria-label="Advanced file filters"><AppIcon name="sliders" />Filters</summary>
            <div className="files-filters">
              <fieldset className="files-segments">
                <legend className="sr-only">File ownership scope</legend>
                <button type="button" aria-pressed={scope === "recent"} onClick={() => setScope("recent")}>
                  Recent
                </button>
                <button type="button" aria-pressed={scope === "shared_by_me"} onClick={() => setScope("shared_by_me")}>
                  Shared by me
                </button>
              </fieldset>
              <label>
                <span>Conversation</span>
                <select value={conversationId} onChange={(event) => setConversationId(event.currentTarget.value)}>
                  <option value="">All conversations</option>
                  {conversations
                    .filter((conversation) => !conversation.archived_at)
                    .sort((left, right) =>
                      conversationParticipantIdentifier(left, duplicateDirectNames)
                        .localeCompare(
                          conversationParticipantIdentifier(
                            right,
                            duplicateDirectNames
                          )
                        )
                    )
                    .map((conversation) => (
                      <option key={conversation.id} value={conversation.id}>
                        {conversationParticipantIdentifier(
                          conversation,
                          duplicateDirectNames
                        )}
                      </option>
                    ))}
                </select>
              </label>
            </div>
          </details>
        </div>

        {downloadError && (
          <div className="files-download-error" role="alert">
            <span>{downloadError}</span>
            <button type="button" aria-label="Dismiss download error" onClick={() => setDownloadError(null)}><AppIcon name="x" /></button>
          </div>
        )}

        {error && (
          <div className="files-state error" role="alert">
            <div>
              <strong>Files could not be loaded.</strong>
              <span>{error}</span>
            </div>
            <button type="button" onClick={() => void loadFiles("replace")}>Try again</button>
          </div>
        )}

        {loading && files.length === 0 ? (
          <div className="files-state" role="status" aria-live="polite">
            <span className="spinner" aria-hidden="true" />
            Loading files…
          </div>
        ) : !error && files.length === 0 ? (
          <div className="files-state empty">
            <strong>No shared files</strong>
          </div>
        ) : !error && visibleFiles.length === 0 ? (
          <div className="files-state empty">
            <strong>No {category} found</strong>
          </div>
        ) : (
          <>
          {visibleFiles.length > 0 && <div className="files-column-heads" aria-hidden="true">
            <span />
            <span>Name</span>
            <span>Shared by</span>
            <span>Conversation</span>
            <span>Size</span>
            <span>Added</span>
            <span />
          </div>}
          <ol className="files-list" aria-busy={loadingMore}>
            {visibleFiles.map((file) => (
              <FileRow
                key={file.id}
                file={file}
                conversation={conversationById.get(file.conversation_id)}
                owner={userById.get(file.owner_user_id)}
                duplicateDirectNames={duplicateDirectNames}
                duplicateUserNames={duplicateUserNames}
                downloading={downloadingId === file.id}
                onDownload={() => void openDownload(file)}
              />
            ))}
          </ol>
          </>
        )}

        {hasMore && !error && (
          <button
            className="files-load-more"
            type="button"
            disabled={loadingMore || !nextCursor}
            onClick={() => void loadFiles("append", nextCursor)}
          >
            {loadingMore ? "Loading…" : "Load more files"}
          </button>
        )}
      </section>
    </main>
  );
}

function FileRow({
  file,
  conversation,
  owner,
  duplicateDirectNames,
  duplicateUserNames,
  downloading,
  onDownload
}: {
  file: FileSummary;
  conversation?: Conversation;
  owner?: User;
  duplicateDirectNames: ReadonlySet<string>;
  duplicateUserNames: ReadonlySet<string>;
  downloading: boolean;
  onDownload: () => void;
}) {
  const sourceTitle = conversation
    ? conversationParticipantIdentifier(conversation, duplicateDirectNames)
    : "Conversation";
  const ownerIdentifier = owner
    ? participantIdentifier(owner, duplicateUserNames)
    : "a member";
  const sharedAt = file.shared_at || file.uploaded_at || file.inserted_at;
  return (
    <li className="file-row">
      <div className={`file-kind-mark ${fileKindTone(file)}`} aria-hidden="true">{fileExtension(file.file_name)}</div>
      <div className="file-row-copy">
        <div className="file-row-title">
          <strong>{file.file_name}</strong>
          {/*
            * A status pill should mark the exception, not the rule. "Available"
            * on every row was five badges saying nothing; the ones that matter --
            * blocked, scanning, failed -- were indistinguishable from the noise.
            * Available files still announce their state to assistive technology.
            */}
          {file.safety_state === "available"
            ? <span className="visually-hidden">{safetyLabel(file.safety_state)}</span>
            : <span className={`file-safety ${file.safety_state}`}>{safetyLabel(file.safety_state)}</span>}
        </div>
        {/*
          * The meta keeps its two-line reading order and its separators, which
          * is what phones render. The classes exist so the desktop layer can
          * lift these into columns with display: contents and place each one by
          * name — reordering there without moving anything here.
          */}
        <p>
          <span className="file-row-size">{formatBytes(file.byte_size)}</span>
          <span aria-hidden="true"> · </span>
          <span className="file-row-source">{sourceTitle}</span>
        </p>
        <p>
          <span className="file-row-owner">Shared by {ownerIdentifier}</span>
          <span aria-hidden="true"> · </span>
          <time className="file-row-time" dateTime={sharedAt}>{formatDateTime(sharedAt)}</time>
        </p>
      </div>
      <div className="file-row-actions">
        <Link
          to={sourceMessagePath(file)}
          aria-label={`View source message for ${file.file_name}`}
        >
          <AppIcon name="externalLink" />
          <span className="file-row-action-label">View message</span>
        </Link>
        <button
          type="button"
          disabled={!file.downloadable || file.safety_state !== "available" || downloading}
          aria-label={`Download ${file.file_name}`}
          title={downloadTitle(file)}
          onClick={onDownload}
        >
          <AppIcon name="download" />
          <span className="file-row-action-label">{downloading ? "Opening…" : "Download"}</span>
        </button>
      </div>
    </li>
  );
}

function mergeFiles(current: FileSummary[], incoming: FileSummary[]): FileSummary[] {
  const byId = new Map(current.map((file) => [file.id, file]));
  incoming.forEach((file) => byId.set(file.id, file));
  return [...byId.values()];
}

function sourceMessagePath(file: FileSummary): string {
  const query = new URLSearchParams({
    conversation: file.conversation_id,
    search_message: file.message_id,
    search_sequence: String(file.conversation_sequence)
  });
  return `/app/?${query.toString()}`;
}

function fileExtension(fileName: string): string {
  const extension = fileName.split(".").pop()?.trim().toLocaleUpperCase();
  if (!extension || extension === fileName.toLocaleUpperCase()) return "FILE";
  return extension.slice(0, 4);
}

function fileCategory(file: FileSummary): Exclude<FileCategory, "all"> {
  if (file.content_type?.toLocaleLowerCase().startsWith("image/")) return "images";
  return "documents";
}

function fileKindTone(file: FileSummary): string {
  const extension = fileExtension(file.file_name).toLocaleLowerCase();
  if (fileCategory(file) === "images") return "image";
  if (extension === "xlsx" || extension === "xls" || extension === "csv") return "sheet";
  if (extension === "ppt" || extension === "pptx") return "slides";
  if (extension === "pdf") return "pdf";
  return "document";
}

function safetyLabel(state: FileSafetyState): string {
  switch (state) {
    case "available": return "Available";
    case "processing": return "Safety check";
    case "blocked": return "Blocked";
    case "failed": return "Scan failed";
    case "unavailable": return "Unavailable";
  }
}

function downloadTitle(file: FileSummary): string {
  if (file.downloadable && file.safety_state === "available") return `Download ${file.file_name}`;
  if (file.safety_state === "processing") return "Download is available after the safety check passes";
  if (file.safety_state === "blocked") return "This file was blocked by the safety check";
  if (file.safety_state === "failed") return "The safety check failed; download remains unavailable";
  return "This file is unavailable";
}
