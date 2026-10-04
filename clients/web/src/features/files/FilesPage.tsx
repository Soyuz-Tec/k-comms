import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router";
import { downloadUrl } from "../../api";
import type { ApiClient } from "../../api";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { createPortal } from "react-dom";
import { useModalDialog } from "../../components/useModalDialog";
import { AppIcon } from "../../components/AppIcon";
import { fileSourceMessagePath } from "../../lib/fileLinks";
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
type FileCategory = "all" | "non_images" | "images";

export function FilesPage() {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const linkedConversationId = searchParams.get("conversation") || "";
  const linkedFileId = searchParams.get("file") || "";
  const { api, session } = useSession();
  const { conversations, users } = useWorkspaceData();
  const [scope, setScope] = useState<FilesScope>("recent");
  const [searchText, setSearchText] = useState("");
  const [query, setQuery] = useState("");
  const [searchError, setSearchError] = useState<string | null>(null);
  const [detailsFile, setDetailsFile] = useState<FileSummary | null>(null);
  const [sharing, setSharing] = useState(false);
  const [shareConversationId, setShareConversationId] = useState("");
  const [category, setCategory] = useState<FileCategory>("all");
  const [conversationId, setConversationId] = useState(linkedConversationId);
  const [files, setFiles] = useState<FileSummary[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [downloadError, setDownloadError] = useState<string | null>(null);
  const [downloadingId, setDownloadingId] = useState<string | null>(null);
  const requestGeneration = useRef(0);
  const focusedFile = useRef("");

  useEffect(() => {
    setConversationId(linkedConversationId);
    setCategory("all");
    focusedFile.current = "";
  }, [linkedConversationId, linkedFileId]);

  const loadFiles = useCallback(async (mode: "replace" | "append", cursor?: string | null) => {
    const generation = ++requestGeneration.current;
    if (mode === "replace") setLoading(true);
    else setLoadingMore(true);
    setError(null);

    try {
      const page = await api.files({
        scope,
        q: query || undefined,
        category: category === "all" ? undefined : category,
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
  }, [api, category, conversationId, query, scope]);

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
  const visibleFiles = files;
  const linkedFileLoaded = files.some((file) => file.id === linkedFileId);
  useEffect(() => {
    if (!linkedFileId || focusedFile.current === linkedFileId || !visibleFiles.some((file) => file.id === linkedFileId)) return;
    const row = document.getElementById(`file-${linkedFileId}`);
    if (row) {
      row.focus();
      row.scrollIntoView({ block: "nearest" });
      focusedFile.current = linkedFileId;
    }
  }, [linkedFileId, visibleFiles]);
  const activeFilterCount = Number(scope !== "recent") + Number(Boolean(conversationId)) + Number(Boolean(query));
  const selectedConversation = conversationById.get(conversationId);
  const selectedConversationTitle = selectedConversation
    ? conversationParticipantIdentifier(selectedConversation, duplicateDirectNames)
    : "Selected conversation";
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
        <div className="files-heading-actions">
          <button className="button primary" type="button" onClick={() => { setShareConversationId(conversationId); setSharing(true); }}>
            <AppIcon name="paperclip" />Share a file
          </button>
          <button
            className="button ghost"
            type="button"
            disabled={loading}
            onClick={() => void loadFiles("replace")}
          >
            <AppIcon name="refresh" />
            {loading ? "Refreshing…" : "Refresh"}
          </button>
          <details className="files-advanced-filter">
            <summary aria-label="Advanced file filters"><AppIcon name="sliders" />Filters{activeFilterCount > 0 && <span className="filter-count">{activeFilterCount}</span>}</summary>
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
      </header>

      <form className="files-search" role="search" onSubmit={(event) => {
        event.preventDefault();
        const next = searchText.trim();
        if (next && (next.length < 2 || next.length > 160)) { setSearchError("Enter between 2 and 160 characters to search filenames."); return; }
        setSearchError(null);
        setQuery(next);
      }}>
        <label className="field grow-field"><span className="files-search-label">Search filenames</span>
          <input type="search" value={searchText} maxLength={160} placeholder="Search filenames" onChange={(event) => setSearchText(event.currentTarget.value)} aria-invalid={Boolean(searchError)} aria-describedby={searchError ? "files-search-error" : undefined} />
        </label>
        <button className="button ghost files-search-submit" type="submit"><AppIcon name="search" /><span>Search files</span></button>
        <label className="field files-mobile-type-picker"><span className="files-search-label">File type</span>
          <select value={category} onChange={(event) => setCategory(event.currentTarget.value as FileCategory)}>
            <option value="all">All types</option>
            <option value="images">Images</option>
            <option value="non_images">Other files</option>
          </select>
        </label>
      </form>
      {searchError && <p id="files-search-error" role="alert">{searchError}</p>}
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
              ["images", "Images"],
              ["non_images", "Other files"]
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
        </div>

        {(activeFilterCount > 0 || category !== "all") && (
          <div className="files-filter-summary" role="status">
            <span>
              {scope === "shared_by_me" ? "Shared by me" : "Recent files"}
              {conversationId && ` · ${selectedConversationTitle}`}
              {category !== "all" && ` · ${category === "images" ? "Images" : "Other files"}`}
              {query && ` · Filename: ${query}`}
            </span>
            <button className="button ghost compact" type="button" onClick={() => {
              setScope("recent");
              setConversationId("");
              setCategory("all");
              setQuery("");
              setSearchText("");
              setSearchError(null);
            }}>Clear filters</button>
          </div>
        )}

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
            <button type="button" onClick={() => void loadFiles(files.length && nextCursor ? "append" : "replace", files.length ? nextCursor : undefined)}>Try again</button>
          </div>
        )}

        {linkedFileId && !linkedFileLoaded && !loading && !error && (
          <p role="status">{hasMore
            ? "The linked file is not in these results yet. Load more files to continue looking."
            : "The linked file is unavailable in these results. It may have been removed or your access may have changed."}</p>
        )}
        {loading && files.length === 0 ? (
          <div className="files-state" role="status" aria-live="polite">
            <span className="spinner" aria-hidden="true" />
            Loading files…
          </div>
        ) : !error && files.length === 0 ? (
          <div className="files-state empty">
            <AppIcon name="file" />
            <strong>{query || category !== "all" ? "No matching files" : "No shared files"}</strong>
            <span>{query || category !== "all" ? "Try a different filename or clear your filters." : "Files shared in your conversations appear here."}</span>
            <Link className="button ghost" to="/app/">Open Inbox</Link>
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
                onDetails={() => setDetailsFile(file)}
              />
            ))}
          </ol>
          </>
        )}

        {hasMore && (
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
      {detailsFile && <FileDetails file={detailsFile} conversation={conversationById.get(detailsFile.conversation_id)} owner={userById.get(detailsFile.owner_user_id)} duplicateDirectNames={duplicateDirectNames} duplicateUserNames={duplicateUserNames} onClose={() => setDetailsFile(null)} onDownload={() => void openDownload(detailsFile)} downloading={downloadingId === detailsFile.id} api={api} />}
      {sharing && <ShareFileDialog conversations={conversations.filter((conversation) => !conversation.archived_at)} duplicateDirectNames={duplicateDirectNames} conversationId={shareConversationId} onSelect={setShareConversationId} onClose={() => setSharing(false)} onContinue={() => {
        const params = new URLSearchParams({ conversation: shareConversationId, compose: "attachment" });
        navigate(`/app/?${params.toString()}`);
      }} />}
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
  onDownload,
  onDetails
}: {
  file: FileSummary;
  conversation?: Conversation;
  owner?: User;
  duplicateDirectNames: ReadonlySet<string>;
  duplicateUserNames: ReadonlySet<string>;
  downloading: boolean;
  onDownload: () => void;
  onDetails: () => void;
}) {
  const sourceTitle = conversation
    ? conversationParticipantIdentifier(conversation, duplicateDirectNames)
    : "Conversation";
  const ownerIdentifier = owner
    ? participantIdentifier(owner, duplicateUserNames)
    : "a member";
  const sharedAt = file.shared_at || file.uploaded_at || file.inserted_at;
  return (
    <li className="file-row" id={`file-${file.id}`} tabIndex={-1}>
      <div className={`file-kind-mark ${fileKindTone(file)}`} aria-hidden="true">{fileExtension(file.file_name)}</div>
      <div className="file-row-copy">
        <div className="file-row-title">
          <button className="file-name-button" type="button" onClick={onDetails} aria-label={`File details for ${file.file_name}`} title={file.file_name}>{file.file_name}</button>
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
          <span className="file-row-source" title={sourceTitle}>{sourceTitle}</span>
        </p>
        <p>
          <span className="file-row-owner" title={ownerIdentifier}>Shared by {ownerIdentifier}</span>
          <span aria-hidden="true"> · </span>
          <time className="file-row-time" dateTime={sharedAt}>{formatDateTime(sharedAt)}</time>
        </p>
      </div>
      <div className="file-row-actions">
        <Link
          to={fileSourceMessagePath(file)}
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

function fileExtension(fileName: string): string {
  const extension = fileName.split(".").pop()?.trim().toLocaleUpperCase();
  if (!extension || extension === fileName.toLocaleUpperCase()) return "FILE";
  return extension.slice(0, 4);
}

function fileCategory(file: FileSummary): Exclude<FileCategory, "all"> {
  if (file.content_type?.toLocaleLowerCase().startsWith("image/")) return "images";
  return "non_images";
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


function FileDetails({ file, conversation, owner, duplicateDirectNames, duplicateUserNames, onClose, onDownload, downloading, api }: {
  file: FileSummary;
  conversation?: Conversation;
  owner?: User;
  duplicateDirectNames: ReadonlySet<string>;
  duplicateUserNames: ReadonlySet<string>;
  onClose: () => void;
  onDownload: () => void;
  downloading: boolean;
  api: Pick<ApiClient, "attachmentDownload">;
}) {
  const dialogRef = useModalDialog(onClose);
  const [preview, setPreview] = useState<string | null>(null);
  const [previewLoading, setPreviewLoading] = useState(false);
  const safeImage = ["image/png", "image/jpeg", "image/webp", "image/gif", "image/avif"].includes(file.content_type.toLowerCase());
  const available = file.downloadable && file.safety_state === "available";
  useEffect(() => {
    if (!safeImage || !available) return;
    let current = true;
    setPreviewLoading(true);
    void api.attachmentDownload(file.id).then((response) => {
      if (current && response.data.status === "ready" && response.data.scan_status === "clean") {
        setPreview(downloadUrl(response.thumbnail_download));
      }
    }).catch(() => undefined).finally(() => { if (current) setPreviewLoading(false); });
    return () => { current = false; };
  }, [api, available, file.id, safeImage]);
  return createPortal(<div className="modal-backdrop">
    <section ref={dialogRef} className="modal-dialog file-details-dialog" role="dialog" aria-modal="true" aria-labelledby="file-details-heading" tabIndex={-1}>
      <header className="app-dialog-heading"><h2 id="file-details-heading">File details</h2><button className="button ghost compact" type="button" data-initial-focus onClick={onClose}>Close</button></header>
      <strong className="file-details-name">{file.file_name}</strong>
      {safeImage && available && <div className="file-details-preview">{preview ? <img src={preview} alt={`Preview of ${file.file_name}`} referrerPolicy="no-referrer" onError={() => setPreview(null)} /> : <p role="status">{previewLoading ? "Loading approved image preview…" : "An image preview is not available. You can download the file or view its source message."}</p>}</div>}
      <dl className="file-details-facts">
        <div><dt>Safety</dt><dd>{safetyLabel(file.safety_state)}</dd></div>
        <div><dt>File type</dt><dd>{file.content_type}</dd></div>
        <div><dt>Size</dt><dd>{formatBytes(file.byte_size)}</dd></div>
        <div><dt>Shared by</dt><dd>{owner ? participantIdentifier(owner, duplicateUserNames) : "A member"}</dd></div>
        <div><dt>Conversation</dt><dd>{conversation ? conversationParticipantIdentifier(conversation, duplicateDirectNames) : "Conversation"}</dd></div>
        <div><dt>Shared</dt><dd>{formatDateTime(file.shared_at || file.inserted_at)}</dd></div>
      </dl>
      {!available && <p role="note">{downloadTitle(file)}</p>}
      <div className="form-actions"><Link className="button ghost" to={fileSourceMessagePath(file)}>View source message</Link><button className="button primary" type="button" disabled={!available || downloading} onClick={onDownload}>{downloading ? "Opening…" : "Download file"}</button></div>
    </section>
  </div>, document.body);
}

function ShareFileDialog({ conversations, duplicateDirectNames, conversationId, onSelect, onClose, onContinue }: {
  conversations: Conversation[];
  duplicateDirectNames: ReadonlySet<string>;
  conversationId: string;
  onSelect: (id: string) => void;
  onClose: () => void;
  onContinue: () => void;
}) {
  const dialogRef = useModalDialog(onClose);
  return createPortal(<div className="modal-backdrop"><section ref={dialogRef} className="modal-dialog" role="dialog" aria-modal="true" aria-labelledby="share-file-heading" tabIndex={-1}>
    <header className="app-dialog-heading"><h2 id="share-file-heading">Share a file</h2><button className="button ghost compact" type="button" onClick={onClose}>Cancel</button></header>
    <p>Choose a conversation, then use Attach file in its message composer. The file follows the existing upload and safety-check process.</p>
    <label className="field">Share in conversation<select value={conversationId} onChange={(event) => onSelect(event.currentTarget.value)} data-initial-focus><option value="">Choose a conversation</option>{conversations.map((conversation) => <option key={conversation.id} value={conversation.id}>{conversationParticipantIdentifier(conversation, duplicateDirectNames)}</option>)}</select></label>
    {conversations.length === 0 && <p>Create or join a conversation in Inbox before sharing files.</p>}
    <div className="form-actions"><button className="button primary" type="button" disabled={!conversations.some((conversation) => conversation.id === conversationId)} onClick={onContinue}>Open message composer</button></div>
  </section></div>, document.body);
}
