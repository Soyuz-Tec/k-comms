import { useEffect, useState } from "react";
import type { ApiClient } from "../../api";
import { AppIcon } from "../../components/AppIcon";
import { AppSurfaceControlButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import { errorText, formatTime } from "../../lib/format";
import type { WorkspaceActivityEntry } from "../../types";

export function ConversationActivityTimeline({
  api,
  conversationId,
  onClose
}: {
  api: ApiClient;
  conversationId: string;
  onClose: () => void;
}) {
  const [entries, setEntries] = useState<WorkspaceActivityEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const dialogRef = useModalDialog(onClose);

  useEffect(() => {
    let current = true;
    void api.conversationActivity(conversationId)
      .then((result) => { if (current) setEntries(result); })
      .catch((reason: unknown) => { if (current) setError(errorText(reason)); })
      .finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [api, conversationId]);

  return <div className="drawer-backdrop">
    <aside id="conversation-activity-panel" ref={dialogRef} className="search-panel activity-timeline" role="dialog" aria-modal="true" aria-labelledby="activity-timeline-title">
      <header><div><span className="eyebrow">Durable workspace history</span><h2 id="activity-timeline-title">Activity</h2></div><AppSurfaceControlButton accessibleLabel="Close activity" kind="close" onClick={onClose} /></header>
      {loading && <p role="status">Loading activity…</p>}
      {error && <div className="form-error" role="alert">{error}</div>}
      {!loading && !error && entries.length === 0 && <p className="empty-copy">No activity has been recorded yet.</p>}
      <ol className="activity-timeline-list">
        {entries.map((entry) => <li key={`${entry.category}:${entry.id}`}><span aria-hidden="true"><AppIcon name={activityIcon(entry.category)} /></span><div><strong>{activityLabel(entry)}</strong>{entry.label && <small>{entry.label}</small>}<time dateTime={entry.occurred_at}>{formatTime(entry.occurred_at)}</time></div></li>)}
      </ol>
    </aside>
  </div>;
}

function activityIcon(category: WorkspaceActivityEntry["category"]): "message" | "whiteboard" | "phone" | "file" {
  if (category === "whiteboard") return "whiteboard";
  if (category === "call") return "phone";
  if (category === "file") return "file";
  return "message";
}

function activityLabel(entry: WorkspaceActivityEntry): string {
  return entry.kind.replaceAll(".", " ").replace(/^\w/, (value) => value.toUpperCase());
}
