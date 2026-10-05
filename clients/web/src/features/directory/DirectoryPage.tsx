import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router";
import { useSession } from "../../app/session";
import { useWorkspaceData } from "../../app/workspace-data";
import { AppIcon } from "../../components/AppIcon";
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
import { callAvailabilityGuidance } from "../calls/callAvailability";
import { useMemberWorkspace, isPrivateAccessDenied } from "../member-workspace/useMemberWorkspace";
import { ContactToggle, PrivateContacts } from "../member-workspace/PrivateContacts";
import "./DirectoryPage.css";

type DirectorySection = "people" | "rooms" | "contacts" | "groups";
type StartMode = "message" | CallMediaKind;

interface DirectoryRoom {
  conversation: Conversation;
  joined: boolean;
  memberCount?: number;
}

interface DirectoryActionFailure {
  id: string;
  message: string;
  retry: () => void;
}

const pageSize = 25;

export function DirectoryPage() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const { api, session } = useSession();
  const { launchCall } = useCallSession();
  const {
    audioCallsAvailable,
    capabilities,
    conversations,
    loading: workspaceLoading,
    setConversations,
    videoCallsAvailable
  } = useWorkspaceData();
  const memberWorkspace = useMemberWorkspace();
  const privateIdentity = useRef(memberWorkspace.identity);
  privateIdentity.current = memberWorkspace.identity;
  const requestedSection = searchParams.get("section");
  const section: DirectorySection = requestedSection === "rooms" || requestedSection === "contacts" || requestedSection === "groups" ? requestedSection : "people";
  function setSection(value: DirectorySection) {
    const next = new URLSearchParams(searchParams);
    next.set("section", value);
    next.delete("q");
    setSearchParams(next);
  }
  const query = (searchParams.get("q") || "").slice(0, section === "people" ? 120 : 160);
  const [people, setPeople] = useState<DirectoryPerson[]>([]);
  const [publicRooms, setPublicRooms] = useState<PublicChannel[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [actionFailure, setActionFailure] = useState<DirectoryActionFailure | null>(null);
  const [pageError, setPageError] = useState<string | null>(null);
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
    setLoadingMore(false);
    setError(null);
    setActionFailure(null);
    setPageError(null);
    setNextCursor(null);
    setHasMore(false);
    setPeople([]);
    setPublicRooms([]);
    if (section === "contacts" || section === "groups") {
      setLoading(false);
      return () => { requestGeneration.current += 1; };
    }

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
  }, [allowPublicRooms, api, memberWorkspace.identity, query, retryGeneration, section]);

  if (!session) return null;
  const audioEnabled =
    capabilities?.allow_audio_calls === true && audioCallsAvailable;
  const videoEnabled =
    capabilities?.allow_video_calls === true && videoCallsAvailable;
  const callGuidance = !workspaceLoading && capabilities
    ? callAvailabilityGuidance({
        allowAudio: capabilities.allow_audio_calls === true,
        allowVideo: capabilities.allow_video_calls === true,
        audioAvailable: audioCallsAvailable,
        videoAvailable: videoCallsAvailable
      })
    : null;
  const callAvailabilityChecking = workspaceLoading || !capabilities;
  const callAvailabilityDescriptionId = callGuidance
    ? "directory-call-availability"
    : undefined;

  function openConversation(conversation: Conversation, mode: StartMode) {
    if (mode !== "message") {
      launchCall(conversation, mode);
      return;
    }
    const params = new URLSearchParams({ conversation: conversation.id });
    navigate(`/app/?${params.toString()}`);
  }

  function retainConversation(conversation: Conversation) {
    setConversations((current) => [
      conversation,
      ...current.filter(({ id }) => id !== conversation.id)
    ]);
  }

  async function startWithPerson(person: DirectoryPerson, mode: StartMode) {
    const generation = requestGeneration.current;
    const actionKey = `${person.id}:${mode}`;
    setBusyAction(actionKey);
    setActionFailure(null);
    try {
      const response = await api.directConversation(person.id);
      if (generation !== requestGeneration.current) return;
      retainConversation(response.data);
      openConversation(response.data, mode);
    } catch (reason: unknown) {
      if (generation === requestGeneration.current) setActionFailure({ id: person.id, message: errorText(reason), retry: () => void startWithPerson(person, mode) });
    } finally {
      setBusyAction((current) => current === actionKey ? null : current);
    }
  }

  async function startPrivateRecipients(ids: string[], title: string | null, mode: StartMode, expectedVersion: number) {
    const generation = requestGeneration.current;
    const identity = memberWorkspace.identity;
    setBusyAction("private-recipients");
    setError(null);
    let attemptedCreation = false;
    try {
      const current = await memberWorkspace.refresh();
      if (!current || identity !== privateIdentity.current || generation !== requestGeneration.current) return;
      if (current.version !== expectedVersion) throw new Error("Contacts changed elsewhere. Review the current selected people before starting.");
      const activeIds = new Set(current.contacts.map(({ id }) => id));
      if (!ids.length || ids.some((id) => !activeIds.has(id))) throw new Error("A selected contact is unavailable. Review the current list before starting.");
      attemptedCreation = true;
      const conversation = ids.length === 1
        ? (await api.directConversation(ids[0]!)).data
        : await api.createConversation({ title: title || "Contact conversation", kind: "group", visibility: "private", member_ids: ids });
      if (identity !== privateIdentity.current || generation !== requestGeneration.current) return;
      retainConversation(conversation);
      openConversation(conversation, mode);
    } catch (reason: unknown) {
      if (identity !== privateIdentity.current || generation !== requestGeneration.current) return;
      if (isPrivateAccessDenied(reason)) memberWorkspace.denyAccess();
      setError(`${errorText(reason)}${attemptedCreation ? " Check your conversations before starting again if the request may have reached the server." : ""}`);
    } finally {
      if (identity === privateIdentity.current) setBusyAction(null);
    }
  }

  async function openRoom(room: DirectoryRoom, mode: StartMode) {
    const generation = requestGeneration.current;
    const actionKey = `${room.conversation.id}:${mode}`;
    setBusyAction(actionKey);
    setActionFailure(null);
    try {
      let conversation = room.conversation;
      if (!room.joined) {
        const response = await api.joinPublicChannel(room.conversation.id);
        if (generation !== requestGeneration.current) return;
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
      if (generation !== requestGeneration.current) return;
      openConversation(conversation, mode);
    } catch (reason: unknown) {
      if (generation === requestGeneration.current) setActionFailure({ id: room.conversation.id, message: errorText(reason), retry: () => void openRoom(room, mode) });
    } finally {
      setBusyAction((current) => current === actionKey ? null : current);
    }
  }

  async function loadMore() {
    if (!nextCursor || loadingMore) return;
    const generation = ++requestGeneration.current;
    setLoadingMore(true);
    setPageError(null);
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
      if (generation === requestGeneration.current) setPageError(errorText(reason));
    } finally {
      if (generation === requestGeneration.current) setLoadingMore(false);
    }
  }

  return (
    <main className="directory-page member-page" id="main-content">
      <header className="member-page-heading">
        <div>
          <h1>Directory</h1>
        </div>
      </header>

      {callGuidance && (
        <p className="call-availability-guidance" id="directory-call-availability" role="status">
          <span>{callGuidance}</span>
          <Link to="/app/calls">Open Calls</Link>
        </p>
      )}
      {callAvailabilityChecking && (
        <p className="call-availability-guidance" role="status">
          Checking call availability…
        </p>
      )}

      {error && (
        <div className="inline-notice error directory-notice" role="alert">
          <span>{error}</span>
          <div>
            <button type="button" onClick={() => setRetryGeneration((current) => current + 1)}>
              Try again
            </button>
            <button type="button" aria-label="Dismiss error" onClick={() => setError(null)}><AppIcon name="x" /></button>
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
          <button type="button" aria-pressed={section === "contacts"} onClick={() => setSection("contacts")}>Contacts</button>
          <button type="button" aria-pressed={section === "groups"} onClick={() => setSection("groups")}>Groups</button>
        </div>
        <label className="member-search">
          <span className="sr-only">Search {section}</span>
          <AppIcon name="search" />
          <input
            type="search"
            value={query}
            onChange={(event) => {
              const next = new URLSearchParams(searchParams);
              if (event.target.value) next.set("q", event.target.value);
              else next.delete("q");
              setSearchParams(next, { replace: true });
            }}
            placeholder={`Search ${section}`}
            autoComplete="off"
            maxLength={section === "people" ? 120 : 160}
          />
        </label>
        {canInviteTeammates && (
          <Link className="button ghost directory-invite" to="/admin?section=people#admin-invitations">
            <AppIcon name="userPlus" />Invite people
          </Link>
        )}
      </div>

      {section === "people" && memberWorkspace.error && <p role="alert">Contact changes: {memberWorkspace.error}</p>}

      {section === "contacts" || section === "groups" ? (
        <PrivateContacts key={memberWorkspace.identity} controller={memberWorkspace} section={section} query={query}
          onStart={startPrivateRecipients} busyAction={busyAction !== null} audioEnabled={audioEnabled} videoEnabled={videoEnabled}
          availabilityDescriptionId={callAvailabilityDescriptionId} />
      ) : loading ? (
        <div className="member-status-view" role="status">
          <span className="spinner" aria-hidden="true" />
          Loading directory…
        </div>
      ) : error ? null : section === "people" ? (
        <DirectoryPeople
          key={memberWorkspace.identity}
          people={people}
          contacts={memberWorkspace}
          actionFailure={actionFailure}
          busyAction={busyAction}
          audioEnabled={audioEnabled}
          videoEnabled={videoEnabled}
          callAvailabilityChecking={callAvailabilityChecking}
          availabilityDescriptionId={callAvailabilityDescriptionId}
          showInvite={canInviteTeammates && query.trim().length === 0}
          onStart={startWithPerson}
        />
      ) : (
        <DirectoryRooms
          rooms={rooms}
          actionFailure={actionFailure}
          busyAction={busyAction}
          audioEnabled={audioEnabled}
          videoEnabled={videoEnabled}
          callAvailabilityChecking={callAvailabilityChecking}
          availabilityDescriptionId={callAvailabilityDescriptionId}
          publicDiscoveryEnabled={allowPublicRooms}
          onOpen={openRoom}
        />
      )}

      {pageError && (
        <div className="inline-notice error directory-notice" role="alert">
          <span>{pageError}</span>
          <button type="button" disabled={loadingMore} onClick={() => void loadMore()}>Retry loading more {section}</button>
        </div>
      )}
      {hasMore && !error && !pageError && (
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
  contacts,
  actionFailure,
  busyAction,
  audioEnabled,
  videoEnabled,
  callAvailabilityChecking,
  availabilityDescriptionId,
  showInvite,
  onStart
}: {
  people: DirectoryPerson[];
  contacts: ReturnType<typeof useMemberWorkspace>;
  actionFailure: DirectoryActionFailure | null;
  busyAction: string | null;
  audioEnabled: boolean;
  videoEnabled: boolean;
  callAvailabilityChecking: boolean;
  availabilityDescriptionId?: string;
  showInvite: boolean;
  onStart: (person: DirectoryPerson, mode: StartMode) => Promise<void>;
}) {
  const duplicateNames = duplicateParticipantNames(people);
  if (people.length === 0) {
    return (
      <DirectoryEmpty
        title={showInvite ? "No teammates yet" : "No people found"}
        detail={showInvite ? undefined : "Try another search."}
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
          <AvatarBadge name={person.display_name} avatarUrl={person.avatar_url} />
          <div className="directory-row-copy">
            <strong>{identifier}</strong>
            {(person.presence_state || person.timezone) && <small>{[person.presence_state && ({ available: "Available", away: "Away", busy: "Busy", dnd: "Do not disturb", offline: "Offline" }[person.presence_state]), person.timezone].filter(Boolean).join(" · ")}</small>}
            {actionFailure?.id === person.id && <DirectoryActionError failure={actionFailure} name={identifier} />}
          </div>
          <ContactToggle person={person} controller={contacts} name={identifier} />
          <QuickActions
            name={identifier}
            busyAction={busyAction}
            actionPrefix={person.id}
            audioEnabled={audioEnabled}
            videoEnabled={videoEnabled}
            callAvailabilityChecking={callAvailabilityChecking}
            availabilityDescriptionId={availabilityDescriptionId}
            onAction={(mode) => void onStart(person, mode)}
          />
        </li>
      })}
    </ul>
  );
}

function DirectoryRooms({
  rooms,
  actionFailure,
  busyAction,
  audioEnabled,
  videoEnabled,
  callAvailabilityChecking,
  availabilityDescriptionId,
  publicDiscoveryEnabled,
  onOpen
}: {
  rooms: DirectoryRoom[];
  actionFailure: DirectoryActionFailure | null;
  busyAction: string | null;
  audioEnabled: boolean;
  videoEnabled: boolean;
  callAvailabilityChecking: boolean;
  availabilityDescriptionId?: string;
  publicDiscoveryEnabled: boolean;
  onOpen: (room: DirectoryRoom, mode: StartMode) => Promise<void>;
}) {
  if (rooms.length === 0) {
    return (
      <DirectoryEmpty
        title="No rooms found"
        detail={publicDiscoveryEnabled
          ? "Try another search."
          : "Public room discovery is disabled."}
      />
    );
  }
  return (
    <ul className="directory-list" aria-label="Rooms">
      {rooms.map((room) => {
        const title = conversationTitle(room.conversation);
        return (
          <li key={room.conversation.id} className="directory-row">
            <span className="room-avatar" aria-hidden="true"><AppIcon name="hash" /></span>
            <div className="directory-row-copy">
              <strong>{title}</strong>
              <small>
                {room.joined ? "Joined room" : `Public room${room.memberCount === undefined ? "" : ` · ${room.memberCount} members`}`}
              </small>
              {actionFailure?.id === room.conversation.id && <DirectoryActionError failure={actionFailure} name={title} />}
            </div>
            <QuickActions
              name={title}
              actionPrefix={room.conversation.id}
              busyAction={busyAction}
              audioEnabled={audioEnabled}
              videoEnabled={videoEnabled}
              callAvailabilityChecking={callAvailabilityChecking}
              availabilityDescriptionId={availabilityDescriptionId}
              messageLabel={room.joined ? "Message" : "Join & open"}
              onAction={(mode) => void onOpen(room, mode)}
            />
          </li>
        );
      })}
    </ul>
  );
}

function DirectoryActionError({ failure, name }: { failure: DirectoryActionFailure; name: string }) {
  return <div className="directory-action-error" role="alert"><span>{failure.message}</span><button className="button ghost compact" type="button" aria-label={`Retry action for ${name}`} onClick={failure.retry}>Retry</button></div>;
}

function QuickActions({
  name,
  actionPrefix,
  busyAction,
  audioEnabled,
  videoEnabled,
  callAvailabilityChecking,
  availabilityDescriptionId,
  messageLabel = "Message",
  onAction
}: {
  name: string;
  actionPrefix: string;
  busyAction?: string | null;
  audioEnabled: boolean;
  videoEnabled: boolean;
  callAvailabilityChecking: boolean;
  availabilityDescriptionId?: string;
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
        disabled={callAvailabilityChecking || !audioEnabled || busy}
        aria-label={callAvailabilityChecking
          ? `Checking audio call availability for ${name}`
          : audioEnabled
            ? `Audio call ${name}`
            : `Audio call unavailable for ${name}`}
        aria-describedby={!callAvailabilityChecking && !audioEnabled ? availabilityDescriptionId : undefined}
        title={callAvailabilityChecking
          ? "Checking audio call availability"
          : audioEnabled
            ? `Audio call ${name}`
            : "Audio calls are unavailable"}
        onClick={() => onAction("audio")}
      >
        <AppIcon name="phone" />
      </button>
      <button
        className="directory-action icon"
        type="button"
        disabled={callAvailabilityChecking || !videoEnabled || busy}
        aria-label={callAvailabilityChecking
          ? `Checking video call availability for ${name}`
          : videoEnabled
            ? `Video call ${name}`
            : `Video call unavailable for ${name}`}
        aria-describedby={!callAvailabilityChecking && !videoEnabled ? availabilityDescriptionId : undefined}
        title={callAvailabilityChecking
          ? "Checking video call availability"
          : videoEnabled
            ? `Video call ${name}`
            : "Video calls are unavailable"}
        onClick={() => onAction("video")}
      >
        <AppIcon name="video" />
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
  detail?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="member-status-view">
      <AppIcon name="users" />
      <h2>{title}</h2>
      {detail && <p>{detail}</p>}
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
