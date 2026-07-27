import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate } from "react-router";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { AvatarBadge } from "../../components/AvatarBadge";
import { conversationTitle, errorText } from "../../lib/format";
import {
  duplicateParticipantNames,
  participantIdentifier
} from "../../lib/participantIdentity";
import { canManageUsers } from "../../lib/roles";
import type {
  CallMediaKind,
  Conversation,
  DirectoryPerson,
  PublicChannel
} from "../../types";
import { useCallSession } from "../calls/CallSessionProvider";

type DirectorySection = "people" | "rooms";
type StartMode = "message" | CallMediaKind;

interface DirectoryRoom {
  conversation: Conversation;
  joined: boolean;
  memberCount?: number;
}

const pageSize = 25;

export function DirectoryPage() {
  const navigate = useNavigate();
  const { api, session } = useSession();
  const { launchCall } = useCallSession();
  const {
    audioCallsAvailable,
    capabilities,
    conversations,
    setConversations,
    videoCallsAvailable
  } = useWorkspaceData();
  const [section, setSection] = useState<DirectorySection>("people");
  const [query, setQuery] = useState("");
  const [people, setPeople] = useState<DirectoryPerson[]>([]);
  const [publicRooms, setPublicRooms] = useState<PublicChannel[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [retryGeneration, setRetryGeneration] = useState(0);
  const requestGeneration = useRef(0);

  const normalizedQuery = query.trim().toLocaleLowerCase();
  const rooms = useMemo(
    () => mergeRooms(conversations, publicRooms, normalizedQuery),
    [conversations, normalizedQuery, publicRooms]
  );
  const allowPublicRooms = capabilities?.allow_public_channels === true;
  const canInviteTeammates = canManageUsers(session?.user.role || "member");

  useEffect(() => {
    const generation = ++requestGeneration.current;
    setLoading(true);
    setError(null);
    setNextCursor(null);
    setHasMore(false);

    const timer = window.setTimeout(() => {
      const load = section === "people"
        ? api.directoryUsers(query.trim(), pageSize)
        : allowPublicRooms
          ? api.discoverPublicChannels(query.trim(), pageSize)
          : Promise.resolve({
              data: [],
              page: { limit: pageSize, has_more: false, next_cursor: null }
            });

      void load
        .then((page) => {
          if (generation !== requestGeneration.current) return;
          if (section === "people") {
            setPeople(page.data as DirectoryPerson[]);
            setNextCursor(page.page.next_cursor);
            setHasMore(Boolean(page.page.next_cursor));
          } else {
            const visible = (page.data as PublicChannel[]).filter(isVisiblePublicRoom);
            setPublicRooms(visible);
            setNextCursor(page.page.next_cursor);
            setHasMore("has_more" in page.page ? page.page.has_more : Boolean(page.page.next_cursor));
          }
        })
        .catch((reason: unknown) => {
          if (generation === requestGeneration.current) setError(errorText(reason));
        })
        .finally(() => {
          if (generation === requestGeneration.current) setLoading(false);
        });
    }, query ? 200 : 0);

    return () => {
      window.clearTimeout(timer);
      requestGeneration.current += 1;
    };
  }, [allowPublicRooms, api, query, retryGeneration, section]);

  if (!session) return null;
  const audioEnabled =
    capabilities?.allow_audio_calls === true && audioCallsAvailable;
  const videoEnabled =
    capabilities?.allow_video_calls === true && videoCallsAvailable;

  function openConversation(conversation: Conversation, mode: StartMode) {
    if (mode !== "message") {
      launchCall(conversation, mode);
      return;
    }
    const params = new URLSearchParams({ conversation: conversation.id });
    navigate(`/app?${params.toString()}`);
  }

  function retainConversation(conversation: Conversation) {
    setConversations((current) => [
      conversation,
      ...current.filter(({ id }) => id !== conversation.id)
    ]);
  }

  async function startWithPerson(person: DirectoryPerson, mode: StartMode) {
    const actionKey = `${person.id}:${mode}`;
    setBusyAction(actionKey);
    setError(null);
    try {
      const response = await api.directConversation(person.id);
      retainConversation(response.data);
      openConversation(response.data, mode);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusyAction(null);
    }
  }

  async function openRoom(room: DirectoryRoom, mode: StartMode) {
    const actionKey = `${room.conversation.id}:${mode}`;
    setBusyAction(actionKey);
    setError(null);
    try {
      let conversation = room.conversation;
      if (!room.joined) {
        const response = await api.joinPublicChannel(room.conversation.id);
        conversation = response.data.conversation;
        retainConversation(conversation);
        setPublicRooms((current) => current.map((candidate) =>
          candidate.id === conversation.id
            ? {
                ...candidate,
                ...conversation,
                joined: true,
                member_count: candidate.member_count + 1,
                membership: response.data.membership
              }
            : candidate
        ));
      }
      openConversation(conversation, mode);
    } catch (reason: unknown) {
      setError(errorText(reason));
    } finally {
      setBusyAction(null);
    }
  }

  async function loadMore() {
    if (!nextCursor || loadingMore) return;
    const generation = ++requestGeneration.current;
    setLoadingMore(true);
    setError(null);
    try {
      if (section === "people") {
        const page = await api.directoryUsers(query.trim(), pageSize, nextCursor);
        if (generation !== requestGeneration.current) return;
        setPeople((current) => mergePeople(current, page.data));
        setNextCursor(page.page.next_cursor);
        setHasMore(Boolean(page.page.next_cursor));
      } else {
        const page = await api.discoverPublicChannels(query.trim(), pageSize, nextCursor);
        if (generation !== requestGeneration.current) return;
        setPublicRooms((current) => mergePublicRooms(
          current,
          page.data.filter(isVisiblePublicRoom)
        ));
        setNextCursor(page.page.next_cursor);
        setHasMore(page.page.has_more);
      }
    } catch (reason: unknown) {
      if (generation === requestGeneration.current) setError(errorText(reason));
    } finally {
      if (generation === requestGeneration.current) setLoadingMore(false);
    }
  }

  return (
    <main className="directory-page member-page" id="main-content">
      <header className="member-page-heading">
        <div>
          <span className="eyebrow">Workspace directory</span>
          <h1>Find people and rooms</h1>
          <p>Start a message or open a call lobby without hunting through menus.</p>
        </div>
      </header>

      {error && (
        <div className="inline-notice error directory-notice" role="alert">
          <span>{error}</span>
          <div>
            <button type="button" onClick={() => setRetryGeneration((current) => current + 1)}>
              Try again
            </button>
            <button type="button" aria-label="Dismiss error" onClick={() => setError(null)}>×</button>
          </div>
        </div>
      )}

      <div className="directory-toolbar">
        <div className="member-segmented-control" role="group" aria-label="Directory type">
          <button
            type="button"
            aria-pressed={section === "people"}
            onClick={() => setSection("people")}
          >
            People
          </button>
          <button
            type="button"
            aria-pressed={section === "rooms"}
            onClick={() => setSection("rooms")}
          >
            Rooms
          </button>
        </div>
        <label className="member-search">
          <span className="sr-only">Search {section}</span>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true">
            <circle cx="10.5" cy="10.5" r="6.5" />
            <path d="m16 16 5 5" />
          </svg>
          <input
            type="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={`Search ${section}`}
            autoComplete="off"
            maxLength={section === "people" ? 120 : 160}
          />
        </label>
      </div>

      {loading ? (
        <div className="member-status-view" role="status">
          <span className="spinner" aria-hidden="true" />
          Loading directory…
        </div>
      ) : error ? null : section === "people" ? (
        <DirectoryPeople
          people={people}
          busyAction={busyAction}
          audioEnabled={audioEnabled}
          videoEnabled={videoEnabled}
          showInvite={canInviteTeammates && query.trim().length === 0}
          onStart={startWithPerson}
        />
      ) : (
        <DirectoryRooms
          rooms={rooms}
          busyAction={busyAction}
          audioEnabled={audioEnabled}
          videoEnabled={videoEnabled}
          publicDiscoveryEnabled={allowPublicRooms}
          onOpen={openRoom}
        />
      )}

      {hasMore && !error && (
        <button
          className="button ghost full directory-load-more"
          type="button"
          disabled={loadingMore || !nextCursor}
          onClick={() => void loadMore()}
        >
          {loadingMore ? "Loading…" : `Load more ${section}`}
        </button>
      )}
    </main>
  );
}

function DirectoryPeople({
  people,
  busyAction,
  audioEnabled,
  videoEnabled,
  showInvite,
  onStart
}: {
  people: DirectoryPerson[];
  busyAction: string | null;
  audioEnabled: boolean;
  videoEnabled: boolean;
  showInvite: boolean;
  onStart: (person: DirectoryPerson, mode: StartMode) => Promise<void>;
}) {
  const duplicateNames = duplicateParticipantNames(people);
  if (people.length === 0) {
    return (
      <DirectoryEmpty
        title={showInvite ? "Your workspace is ready for teammates" : "No people found"}
        detail={showInvite
          ? "Invite the first teammate now, then return here to message or call them."
          : "Try a different name or clear the search."}
        action={showInvite
          ? <Link className="button primary directory-empty-action" to="/admin?section=people#admin-invitations">Invite your first teammate</Link>
          : undefined}
      />
    );
  }
  return (
    <ul className="directory-list" aria-label="People">
      {people.map((person) => {
        const identifier = participantIdentifier(person, duplicateNames);
        return <li key={person.id} className="directory-row">
          <AvatarBadge name={person.display_name} />
          <div className="directory-row-copy">
            <strong>{identifier}</strong>
            <small>Workspace member</small>
          </div>
          <QuickActions
            name={identifier}
            busyAction={busyAction}
            actionPrefix={person.id}
            audioEnabled={audioEnabled}
            videoEnabled={videoEnabled}
            onAction={(mode) => void onStart(person, mode)}
          />
        </li>
      })}
    </ul>
  );
}

function DirectoryRooms({
  rooms,
  busyAction,
  audioEnabled,
  videoEnabled,
  publicDiscoveryEnabled,
  onOpen
}: {
  rooms: DirectoryRoom[];
  busyAction: string | null;
  audioEnabled: boolean;
  videoEnabled: boolean;
  publicDiscoveryEnabled: boolean;
  onOpen: (room: DirectoryRoom, mode: StartMode) => Promise<void>;
}) {
  if (rooms.length === 0) {
    return (
      <DirectoryEmpty
        title="No rooms found"
        detail={publicDiscoveryEnabled
          ? "Try a different room name or clear the search."
          : "No joined rooms match this search. Public room discovery is disabled by workspace policy."}
      />
    );
  }
  return (
    <ul className="directory-list" aria-label="Rooms">
      {rooms.map((room) => {
        const title = conversationTitle(room.conversation);
        return (
          <li key={room.conversation.id} className="directory-row">
            <span className="room-avatar" aria-hidden="true">#</span>
            <div className="directory-row-copy">
              <strong>{title}</strong>
              <small>
                {room.joined ? "Joined room" : `Public room${room.memberCount === undefined ? "" : ` · ${room.memberCount} members`}`}
              </small>
            </div>
            <QuickActions
              name={title}
              actionPrefix={room.conversation.id}
              busyAction={busyAction}
              audioEnabled={audioEnabled}
              videoEnabled={videoEnabled}
              messageLabel={room.joined ? "Message" : "Join & open"}
              onAction={(mode) => void onOpen(room, mode)}
            />
          </li>
        );
      })}
    </ul>
  );
}

function QuickActions({
  name,
  actionPrefix,
  busyAction,
  audioEnabled,
  videoEnabled,
  messageLabel = "Message",
  onAction
}: {
  name: string;
  actionPrefix: string;
  busyAction?: string | null;
  audioEnabled: boolean;
  videoEnabled: boolean;
  messageLabel?: string;
  onAction: (mode: StartMode) => void;
}) {
  const busy = busyAction?.startsWith(`${actionPrefix}:`) === true;
  return (
    <div className="directory-actions" role="group" aria-label={`Contact ${name}`}>
      <button
        className="directory-action primary"
        type="button"
        disabled={busy}
        aria-label={`${messageLabel} ${name}`}
        onClick={() => onAction("message")}
      >
        {busyAction === `${actionPrefix}:message` ? "Opening…" : messageLabel}
      </button>
      <button
        className="directory-action icon"
        type="button"
        disabled={!audioEnabled || busy}
        aria-label={`Audio call ${name}`}
        title={audioEnabled ? `Audio call ${name}` : "Audio calls are unavailable"}
        onClick={() => onAction("audio")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true">
          <path d="M7.2 3.5 10 8 8.4 9.7a13 13 0 0 0 5.9 5.9L16 14l4.5 2.8-.8 3.2c-.2.8-1 1.3-1.8 1.2A17.6 17.6 0 0 1 2.8 6.1C2.7 5.3 3.2 4.5 4 4.3l3.2-.8Z" />
        </svg>
      </button>
      <button
        className="directory-action icon"
        type="button"
        disabled={!videoEnabled || busy}
        aria-label={`Video call ${name}`}
        title={videoEnabled ? `Video call ${name}` : "Video calls are unavailable"}
        onClick={() => onAction("video")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true">
          <rect x="3" y="6" width="13" height="12" rx="2" />
          <path d="m16 10 5-3v10l-5-3" />
        </svg>
      </button>
    </div>
  );
}

function DirectoryEmpty({
  title,
  detail,
  action
}: {
  title: string;
  detail: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="member-status-view">
      <span className="empty-mark" aria-hidden="true">◇</span>
      <h2>{title}</h2>
      <p>{detail}</p>
      {action}
    </div>
  );
}

function mergePeople(
  current: DirectoryPerson[],
  incoming: DirectoryPerson[]
): DirectoryPerson[] {
  return [...new Map([...current, ...incoming].map((person) => [person.id, person])).values()];
}

function mergePublicRooms(
  current: PublicChannel[],
  incoming: PublicChannel[]
): PublicChannel[] {
  return [...new Map([...current, ...incoming].map((room) => [room.id, room])).values()];
}

function mergeRooms(
  conversations: Conversation[],
  publicRooms: PublicChannel[],
  query: string
): DirectoryRoom[] {
  const byId = new Map<string, DirectoryRoom>();
  for (const conversation of conversations) {
    if (
      conversation.kind === "direct" ||
      conversation.archived_at ||
      (query && !conversationTitle(conversation).toLocaleLowerCase().includes(query))
    ) {
      continue;
    }
    byId.set(conversation.id, { conversation, joined: true });
  }
  for (const room of publicRooms) {
    const existing = byId.get(room.id);
    byId.set(room.id, {
      conversation: existing?.conversation || room,
      joined: existing?.joined || room.joined,
      memberCount: room.member_count
    });
  }
  return [...byId.values()].sort((left, right) =>
    conversationTitle(left.conversation).localeCompare(conversationTitle(right.conversation))
  );
}

function isVisiblePublicRoom(room: PublicChannel): boolean {
  return (
    room.kind === "channel" &&
    room.visibility === "tenant" &&
    !room.archived_at
  );
}
