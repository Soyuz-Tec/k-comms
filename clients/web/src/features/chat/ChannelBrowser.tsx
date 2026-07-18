import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import type { ApiClient } from "../../api";
import { useModalDialog } from "../../components/useModalDialog";
import { conversationTitle, errorText, stringValue } from "../../lib/format";
import type { Conversation, PublicChannel } from "../../types";

export function ChannelBrowser({
  api,
  enabled,
  onClose,
  onJoined,
  onOpen
}: {
  api: ApiClient;
  enabled: boolean;
  onClose: () => void;
  onJoined: (conversation: Conversation) => void;
  onOpen: (conversationId: string) => void;
}) {
  const [channels, setChannels] = useState<PublicChannel[]>([]);
  const [query, setQuery] = useState("");
  const [activeQuery, setActiveQuery] = useState("");
  const [cursor, setCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(enabled);
  const [joiningId, setJoiningId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const requestId = useRef(0);
  const dialogRef = useModalDialog(onClose);

  const load = useCallback(async (nextQuery: string, nextCursor: string | null, append: boolean) => {
    if (!enabled) return;
    const currentRequest = ++requestId.current;
    setLoading(true);
    setError(null);
    try {
      const response = await api.discoverPublicChannels(nextQuery, 25, nextCursor);
      if (currentRequest !== requestId.current) return;
      const visible = response.data.filter((channel) => channel.kind === "channel" && channel.visibility === "tenant" && !channel.archived_at);
      setChannels((current) => {
        const values = append ? [...current, ...visible] : visible;
        return [...new Map(values.map((channel) => [channel.id, channel])).values()];
      });
      setCursor(response.page.next_cursor);
      setHasMore(response.page.has_more);
    } catch (reason: unknown) {
      if (currentRequest === requestId.current) setError(errorText(reason));
    } finally {
      if (currentRequest === requestId.current) setLoading(false);
    }
  }, [api, enabled]);

  useEffect(() => {
    if (enabled) void load("", null, false);
    return () => { requestId.current += 1; };
  }, [enabled, load]);

  async function search(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const nextQuery = stringValue(new FormData(event.currentTarget), "channel_query");
    setActiveQuery(nextQuery);
    await load(nextQuery, null, false);
  }

  async function join(channel: PublicChannel) {
    setJoiningId(channel.id);
    setError(null);
    try {
      const response = await api.joinPublicChannel(channel.id);
      setChannels((current) => current.map((value) => value.id === channel.id ? {
        ...value,
        ...response.data.conversation,
        joined: true,
        member_count: value.joined ? value.member_count : value.member_count + 1,
        membership: response.data.membership
      } : value));
      onJoined(response.data.conversation);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setJoiningId(null);
    }
  }

  return (
    <div className="drawer-backdrop">
      <aside ref={dialogRef} className="search-panel channel-browser-panel" role="dialog" aria-modal="true" aria-labelledby="channel-browser-title">
        <header><div><span className="eyebrow">Workspace channels</span><h2 id="channel-browser-title">Browse channels</h2></div><button className="icon-button" type="button" aria-label="Close channel browser" onClick={onClose}>×</button></header>
        {!enabled ? (
          <div className="empty-state compact-empty" role="status"><h3>Channel discovery is disabled</h3><p>Your workspace policy does not allow tenant-visible public channels.</p></div>
        ) : <>
          <form className="search-form" role="search" onSubmit={(event) => void search(event)}>
            <label className="sr-only" htmlFor="channel-search">Search public channels</label>
            <input id="channel-search" name="channel_query" type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search channels" autoFocus data-initial-focus maxLength={160} />
            <button className="button primary compact" type="submit" disabled={loading}>{loading ? "Searching…" : "Search"}</button>
          </form>
          {error && <div className="form-error" role="alert">{error}</div>}
          {!loading && channels.length === 0 && <div className="empty-state compact-empty" role="status"><h3>No public channels found</h3><p>{activeQuery ? "Try a different search." : "There are no tenant-visible channels to join."}</p></div>}
          <ul className="channel-discovery-list">
            {channels.map((channel) => <li key={channel.id}><div><strong>#{conversationTitle(channel)}</strong><small>{channel.member_count} {channel.member_count === 1 ? "member" : "members"}</small></div>{channel.joined ? <button className="button ghost compact" type="button" onClick={() => onOpen(channel.id)}>Open</button> : <button className="button primary compact" type="button" disabled={joiningId === channel.id} onClick={() => void join(channel)}>{joiningId === channel.id ? "Joining…" : "Join"}</button>}</li>)}
          </ul>
          {hasMore && <button className="button ghost full" type="button" disabled={loading || !cursor} onClick={() => void load(activeQuery, cursor, true)}>{loading ? "Loading…" : "Load more channels"}</button>}
        </>}
      </aside>
    </div>
  );
}
