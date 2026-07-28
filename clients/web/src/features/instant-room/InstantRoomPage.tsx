import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { FormEvent } from "react";
import { Link, useNavigate } from "react-router";
import type { ApiClient } from "../../api";
import {
  ApiError,
  GuestApiClient,
  loadStoredGuestSession,
  storeGuestSession
} from "../../api";
import { useSession } from "../../app/session";
import { AppIcon } from "../../components/AppIcon";
import { browserName, formatDateTime } from "../../lib/format";
import {
  isEncryptedUrl
} from "../../lib/transportSecurity";
import type {
  Conversation,
  GuestCapabilities,
  GuestSession,
  InstantRoom,
  InstantRoomResult,
  Session
} from "../../types";
import { GuestShell } from "../guest/GuestAccessPage";
import { QrCode } from "../guest/QrCode";
import {
  DelegatingRoomApi,
  type GuestRoomApi,
  MemberRoomApi
} from "../guest/roomApi";
import {
  beginNewInstantRoomVisit,
  instantRoomIdempotencyKey
} from "./idempotency";
import {
  clearMemberInstantRoomContinuity,
  loadMemberInstantRoomContinuity,
  type MemberInstantRoomContinuity,
  storeMemberInstantRoomContinuity
} from "./memberContinuity";
import "./InstantRoomPage.css";

const apiBase = import.meta.env.VITE_API_BASE_URL || "";
const creationFlights = new Map<string, Promise<InstantRoomResult>>();

interface ActiveRoom {
  mode: "guest" | "member";
  session: GuestSession;
  room?: InstantRoom;
  shareUrl?: string;
  returnsToAccount?: boolean;
}

export function InstantRoomPage() {
  const navigate = useNavigate();
  const {
    api: memberApi,
    session: accountSession,
    setSession: setAccountSession,
    transportPolicyReady,
    accountActionsAllowed,
    mediaActionsAllowed
  } = useSession();
  const secureActionsUnavailable =
    transportPolicyReady &&
    (!accountActionsAllowed || !mediaActionsAllowed);
  const initialStateRef = useRef<{
    guest: GuestSession | null;
    member: MemberInstantRoomContinuity | null;
  } | null>(null);
  if (!initialStateRef.current) {
    const guest = loadStoredGuestSession();
    initialStateRef.current = {
      guest,
      member:
        !guest?.instant_room && accountSession
          ? loadMemberInstantRoomContinuity(accountSession)
          : null
    };
  }
  const [activeRoom, setActiveRoom] = useState<ActiveRoom | null>(() => {
    const guestSession = initialStateRef.current?.guest;
    return guestSession?.instant_room
      ? {
          mode: "guest",
          session: accountSession
            ? withoutGuestConversion(guestSession)
            : guestSession,
          room: guestSession.instant_room,
          shareUrl: guestSession.share_url,
          returnsToAccount: Boolean(accountSession)
        }
      : null;
  });
  const [memberContinuity, setMemberContinuity] =
    useState<MemberInstantRoomContinuity | null>(
      initialStateRef.current.member
    );
  const [loading, setLoading] = useState(
    Boolean(initialStateRef.current.member)
  );
  const [error, setError] = useState("");
  const [retryAt, setRetryAt] = useState<number | null>(null);
  const [retryVersion, setRetryVersion] = useState(0);
  const [leftRoom, setLeftRoom] = useState(false);
  const [clock, setClock] = useState(Date.now());
  const [displayName, setDisplayName] = useState(
    accountSession?.user.display_name || ""
  );
  const [roomTitle, setRoomTitle] = useState("");
  const guestApiRef = useRef<GuestApiClient | null>(null);
  const accountSessionRef = useRef(accountSession);
  const restoredMemberSessionRef = useRef<string | null>(
    initialStateRef.current.member && accountSession
      ? memberSessionIdentity(accountSession)
      : null
  );
  accountSessionRef.current = accountSession;

  const updateGuestSession = useCallback((
    session: GuestSession | null,
    reason?: "access_ended" | "logout"
  ) => {
    if (session) {
      setActiveRoom((current) => {
        const returnsToAccount =
          current?.returnsToAccount || Boolean(accountSessionRef.current);
        const nextSession = returnsToAccount
          ? withoutGuestConversion(session)
          : session;
        storeGuestSession(nextSession);
        return {
          mode: "guest",
          session: nextSession,
          room: nextSession.instant_room || current?.room,
          shareUrl: nextSession.share_url || current?.shareUrl,
          returnsToAccount
        };
      });
      return;
    }
    storeGuestSession(null);
    if (reason === "access_ended") {
      setActiveRoom(null);
      setError(
        "This communication link is unavailable. It may have expired or been revoked."
      );
      setLeftRoom(true);
    }
  }, []);

  if (!guestApiRef.current) {
    guestApiRef.current = new GuestApiClient(
      apiBase,
      activeRoom?.mode === "guest" ? activeRoom.session : null,
      updateGuestSession
    );
  }
  const guestApi = guestApiRef.current;
  guestApi.setSession(activeRoom?.mode === "guest" ? activeRoom.session : null);
  const stableRoomApiRef = useRef<DelegatingRoomApi | null>(null);
  if (!stableRoomApiRef.current) {
    stableRoomApiRef.current = new DelegatingRoomApi(guestApi);
  }
  const stableRoomApi = stableRoomApiRef.current;

  useEffect(() => {
    document.title = "Instant room | K-Comms";
  }, []);

  useEffect(() => {
    if (!transportPolicyReady || !accountSession) return;
    setDisplayName(accountSession.user.display_name);

    if (activeRoom?.mode === "guest" && !activeRoom.returnsToAccount) {
      setActiveRoom({
        ...activeRoom,
        session: withoutGuestConversion(activeRoom.session),
        returnsToAccount: true
      });
      return;
    }

    if (activeRoom || leftRoom || memberContinuity) return;
    const identity = memberSessionIdentity(accountSession);
    if (restoredMemberSessionRef.current === identity) return;
    restoredMemberSessionRef.current = identity;
    const continuity = loadMemberInstantRoomContinuity(accountSession);
    if (!continuity) return;
    setLoading(true);
    setMemberContinuity(continuity);
  }, [
    accountSession,
    activeRoom,
    leftRoom,
    memberContinuity,
    transportPolicyReady
  ]);

  useEffect(() => {
    if (
      !activeRoom ||
      activeRoom.mode !== "member" ||
      (
        accountSession &&
        activeRoom.session.tenant.id === accountSession.tenant.id &&
        activeRoom.session.user.id === accountSession.user.id
      )
    ) {
      return;
    }
    clearMemberInstantRoomContinuity();
    beginNewInstantRoomVisit();
    setMemberContinuity(null);
    setActiveRoom(null);
    setLeftRoom(false);
  }, [accountSession, activeRoom]);

  useEffect(() => {
    if (!accountSession) {
      if (memberContinuity) {
        clearMemberInstantRoomContinuity();
        beginNewInstantRoomVisit();
        setMemberContinuity(null);
      }
      setLoading(false);
      return;
    }
    if (
      !memberContinuity ||
      activeRoom ||
      leftRoom
    ) {
      return;
    }
    let current = true;
    setLoading(true);
    setError("");
    setRetryAt(null);
    void Promise.all([
      memberApi.conversation(memberContinuity.conversation.id),
      memberApi.me()
    ]).then(([conversation, me]) => {
      if (!current) return;
      if (
        conversation.id !== memberContinuity.conversation.id ||
        conversation.archived_at
      ) {
        clearMemberInstantRoomContinuity();
        beginNewInstantRoomVisit();
        setMemberContinuity(null);
        return;
      }
      setActiveRoom({
        mode: "member",
        session: asRoomSession(
          accountSession,
          conversation,
          me.capabilities,
          memberContinuity.room,
          memberContinuity.share_url
        ),
        room: memberContinuity.room,
        shareUrl: memberContinuity.share_url
      });
      setMemberContinuity(null);
    }).catch((reason: unknown) => {
      if (!current) return;
      if (isDefinitiveRoomUnavailable(reason)) {
        clearMemberInstantRoomContinuity();
        beginNewInstantRoomVisit();
        setMemberContinuity(null);
        return;
      }
      setError(
        "K-Comms could not confirm your existing room. Retry to reopen it without creating another room."
      );
    }).finally(() => {
      if (current) setLoading(false);
    });
    return () => {
      current = false;
    };
  }, [
    accountSession,
    activeRoom,
    leftRoom,
    memberApi,
    memberContinuity,
    retryVersion
  ]);

  useEffect(() => {
    if (!retryAt) return;
    const timer = window.setInterval(() => setClock(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, [retryAt]);

  const retrySeconds = retryAt
    ? Math.max(0, Math.ceil((retryAt - clock) / 1_000))
    : 0;

  async function startInstantRoom(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const chosenName =
      accountSession?.user.display_name.trim() || displayName.trim();
    const chosenTitle = roomTitle.trim();
    if (!chosenName || loading || retrySeconds > 0) return;

    if (leftRoom || memberContinuity) {
      clearMemberInstantRoomContinuity();
      beginNewInstantRoomVisit();
      setMemberContinuity(null);
      setLeftRoom(false);
    }

    const key = instantRoomIdempotencyKey();
    setLoading(true);
    setError("");
    setRetryAt(null);

    try {
      const result = await createInstantRoomOnce(memberApi, key, {
        ...(!accountSession ? { display_name: chosenName } : {}),
        ...(chosenTitle ? { title: chosenTitle } : {}),
        device: { name: browserName(), platform: "web" }
      });
      if (!result.share_url) {
        throw new Error(
          "The server created the room but did not return its invite link."
        );
      }

      if (result.guest_session) {
        clearMemberInstantRoomContinuity();
        const returnedGuestSession: GuestSession = {
          ...result.guest_session,
          conversation: result.conversation,
          instant_room: result.room,
          share_url: result.share_url
        };
        const guestSession = accountSession
          ? withoutGuestConversion(returnedGuestSession)
          : returnedGuestSession;
        guestApi.setSession(guestSession);
        storeGuestSession(guestSession);
        setActiveRoom({
          mode: "guest",
          session: guestSession,
          room: result.room,
          shareUrl: result.share_url,
          returnsToAccount: Boolean(accountSession)
        });
        return;
      }

      if (!accountSession) {
        throw new Error(
          "The server did not return the anonymous room creator session."
        );
      }
      const capabilities = await memberApi
        .me()
        .then((response) => response.capabilities)
        .catch(() => unavailableCallCapabilities);
      const memberSession = asRoomSession(
        accountSession,
        result.conversation,
        capabilities,
        result.room,
        result.share_url
      );
      storeMemberInstantRoomContinuity(accountSession, {
        room: result.room,
        conversation: result.conversation,
        share_url: result.share_url
      });
      setActiveRoom({
        mode: "member",
        session: memberSession,
        room: result.room,
        shareUrl: result.share_url
      });
    } catch (reason: unknown) {
      const display = instantRoomError(reason);
      setError(display.message);
      setRetryAt(
        display.retryAfterSeconds
          ? Date.now() + display.retryAfterSeconds * 1_000
          : null
      );
    } finally {
      setLoading(false);
    }
  }
  const selectedRoomApi = useMemo<GuestRoomApi>(() => {
    if (!activeRoom || activeRoom.mode === "guest") return guestApi;
    return new MemberRoomApi(memberApi, activeRoom.session.conversation.id);
  }, [activeRoom, guestApi, memberApi]);
  stableRoomApi.setDelegate(selectedRoomApi);
  const roomApi = activeRoom ? stableRoomApi : null;

  if (loading && !activeRoom) {
    return (
      <main className="instant-room-entry" id="main-content" aria-busy="true">
        <section className="instant-room-loading" aria-labelledby="instant-room-title">
          <KCommsMark />
          <span className="spinner" aria-hidden="true" />
          <h1 id="instant-room-title">Opening your room…</h1>
          <p>Your invite link and QR code will be ready in a moment.</p>
        </section>
      </main>
    );
  }

  if (!activeRoom || !roomApi) {
    return (
      <main className="instant-room-entry" id="main-content">
        <section
          className="instant-room-start"
          aria-labelledby="instant-room-start-title"
        >
          <KCommsMark />
          <span className="instant-room-kicker">
            {leftRoom ? "Start again" : "No account needed"}
          </span>
          <h1 id="instant-room-start-title" data-route-focus>
            Start an instant room
          </h1>
          <p>
            {accountSession
              ? "Create it with your workspace identity, then share the link."
              : "Add your name, share one link, and start talking."}
          </p>
          {!transportPolicyReady && (
            <div className="transport-warning" role="status">
              <strong>Checking the secure connection…</strong>
              <span>
                Secure account and media controls remain unavailable until
                K-Comms verifies this deployment.
              </span>
            </div>
          )}
          {secureActionsUnavailable && (
            <div className="transport-warning" role="alert">
              <strong>Text-only mode is active.</strong>
              <span>
                K-Comms could not verify a trusted HTTPS path to this
                deployment. Use non-sensitive content only. Account actions,
                microphone, camera, and screen sharing remain disabled.
              </span>
            </div>
          )}
          {error && <p className="form-error" role="alert">{error}</p>}
          <form
            className="instant-room-start-form"
            onSubmit={(event) => void startInstantRoom(event)}
          >
            {accountSession ? (
              <p className="instant-room-account-identity">
                <span>Starting as</span>
                <strong>{accountSession.user.display_name}</strong>
                <small>Managed by your workspace profile</small>
              </p>
            ) : (
              <label className="field">
                <span className="instant-room-field-label">
                  Your display name
                </span>
                <span className="instant-room-input">
                  <EntryFieldIcon kind="person" />
                  <input
                    name="display_name"
                    type="text"
                    minLength={1}
                    maxLength={120}
                    autoComplete="name"
                    value={displayName}
                    onChange={(event) => setDisplayName(event.target.value)}
                    placeholder="Your name"
                    required
                    autoFocus
                  />
                </span>
              </label>
            )}
            <label className="field">
              <span className="instant-room-field-label">
                Room name <span className="optional">Optional</span>
              </span>
              <span className="instant-room-input">
                <EntryFieldIcon kind="room" />
                <input
                  name="title"
                  type="text"
                  maxLength={160}
                  autoComplete="off"
                  value={roomTitle}
                  onChange={(event) => setRoomTitle(event.target.value)}
                  placeholder="Daily check-in"
                  autoFocus={Boolean(accountSession)}
                />
              </span>
            </label>
            <button
              className="button primary full"
              type="submit"
              disabled={
                loading ||
                retrySeconds > 0 ||
                !(accountSession?.user.display_name || displayName).trim()
              }
            >
              {loading
                ? "Opening room…"
                : retrySeconds > 0
                ? `Try again in ${retrySeconds}s`
                : error
                  ? "Try again"
                  : "Start instant room"}
            </button>
          </form>
          {memberContinuity && error && (
            <button
              className="button ghost full"
              type="button"
              onClick={() => {
                setLoading(true);
                setRetryVersion((version) => version + 1);
              }}
            >
              Retry existing room
            </button>
          )}
          <div className="instant-room-entry-actions">
            <Link
              className="button ghost"
              to={accountSession ? "/app" : "/sign-in"}
            >
              {accountSession
                ? "Return to workspace"
                : "Have a workspace? Sign in"}
            </Link>
          </div>
        </section>
      </main>
    );
  }

  const shareBanner =
    activeRoom.room && activeRoom.shareUrl ? (
      (participantCount: number) => (
        <InstantRoomSharePanel
          room={activeRoom.room!}
          shareUrl={activeRoom.shareUrl!}
          title={activeRoom.session.conversation.title || "Instant room"}
          participantCount={participantCount}
        />
      )
    ) : undefined;

  return (
    <GuestShell
      api={roomApi}
      initialSession={activeRoom.session}
      accountActionsAllowed={
        transportPolicyReady && accountActionsAllowed
      }
      mediaActionsAllowed={
        transportPolicyReady && mediaActionsAllowed
      }
      identityLabel={activeRoom.mode === "guest" ? "Host" : "Member"}
      initialPresenceCount={1}
      roomBanner={shareBanner}
      onAccessEnded={() => {
        clearMemberInstantRoomContinuity();
        storeGuestSession(null);
        setActiveRoom(null);
        setError(
          "This communication link is unavailable. It may have expired or been revoked."
        );
        setLeftRoom(true);
      }}
      onLeave={() => {
        if (activeRoom.mode === "member" || activeRoom.returnsToAccount) {
          clearMemberInstantRoomContinuity();
          storeGuestSession(null);
          setActiveRoom(null);
          setLeftRoom(true);
          navigate("/app", { replace: true });
        } else {
          clearMemberInstantRoomContinuity();
          storeGuestSession(null);
          setActiveRoom(null);
          setLeftRoom(true);
          setError("");
        }
      }}
      onConverted={(session, conversation) => {
        if (activeRoom.mode === "guest" && activeRoom.returnsToAccount) {
          return;
        }
        storeGuestSession(null);
        setAccountSession(session);
        const registeredRoom = activeRoom.room
          ? {
              ...activeRoom.room,
              owner_user_id: session.user.id,
              owner_kind: "registered" as const
            }
          : undefined;
        const continued = asRoomSession(
          session,
          conversation,
          {
            ...activeRoom.session.capabilities,
            conversion_enabled: false,
            self_service_conversion: false
          },
          registeredRoom,
          activeRoom.shareUrl
        );
        if (registeredRoom && activeRoom.shareUrl) {
          storeMemberInstantRoomContinuity(session, {
            room: registeredRoom,
            conversation,
            share_url: activeRoom.shareUrl
          });
        }
        setActiveRoom({
          ...activeRoom,
          mode: "member",
          session: continued,
          room: registeredRoom
        });
      }}
    />
  );
}

export async function createInstantRoomOnce(
  api: ApiClient,
  idempotencyKey: string,
  input: {
    display_name?: string;
    title?: string;
    device?: { name: string; platform: "web" };
  }
): Promise<InstantRoomResult> {
  const existing = creationFlights.get(idempotencyKey);
  if (existing) return existing;

  const request = createWithOneRetry(api, idempotencyKey, input).catch(
    (reason: unknown) => {
      creationFlights.delete(idempotencyKey);
      throw reason;
    }
  );
  creationFlights.set(idempotencyKey, request);
  return request;
}

async function createWithOneRetry(
  api: ApiClient,
  idempotencyKey: string,
  input: {
    display_name?: string;
    title?: string;
    device?: { name: string; platform: "web" };
  }
): Promise<InstantRoomResult> {
  try {
    return await api.createInstantRoom(input, idempotencyKey);
  } catch (reason: unknown) {
    if (
      reason instanceof ApiError &&
      reason.status === 409 &&
      reason.code === "idempotency_replay_expired"
    ) {
      const rotatedKey = beginNewInstantRoomVisit();
      const rotatedRequest = api.createInstantRoom(input, rotatedKey);
      creationFlights.set(rotatedKey, rotatedRequest);
      return rotatedRequest;
    }
    if (!isTransientCreateFailure(reason)) throw reason;
    await wait(350);
    return api.createInstantRoom(input, idempotencyKey);
  }
}

function isTransientCreateFailure(reason: unknown): boolean {
  return (
    (reason instanceof ApiError && reason.status >= 500) ||
    reason instanceof TypeError
  );
}

function isDefinitiveRoomUnavailable(reason: unknown): boolean {
  return (
    reason instanceof ApiError &&
    [401, 403, 404, 410].includes(reason.status)
  );
}

function wait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

function InstantRoomSharePanel({
  room,
  shareUrl,
  title,
  participantCount
}: {
  room: InstantRoom;
  shareUrl: string;
  title: string;
  participantCount: number;
}) {
  const [notice, setNotice] = useState("");
  const [expanded, setExpanded] = useState(true);
  const [linkRevealed, setLinkRevealed] = useState(false);
  const secureLink = isEncryptedUrl(shareUrl);
  const titleRef = useRef<HTMLHeadingElement>(null);
  const lifetime = instantRoomLifetime(room);

  useEffect(() => {
    if (expanded) titleRef.current?.focus();
  }, [expanded]);

  useEffect(() => {
    if (participantCount > 1) setExpanded(false);
  }, [participantCount]);

  async function copyLink() {
    try {
      await copyText(shareUrl);
      setNotice(`${secureLink ? "Secure link" : "Invite link"} copied.`);
      setExpanded(false);
    } catch {
      setLinkRevealed(true);
      setExpanded(true);
      setNotice("Copy failed. The full link is visible so you can copy it manually.");
    }
  }

  async function shareLink() {
    if (!navigator.share) {
      await copyLink();
      return;
    }
    try {
      await navigator.share({
        title: `${title} on K-Comms`,
        text: "Join my K-Comms room. No account is required.",
        url: shareUrl
      });
      setNotice("Share sheet opened.");
      setExpanded(false);
    } catch (reason: unknown) {
      if (
        !(reason instanceof DOMException) ||
        reason.name !== "AbortError"
      ) {
        setNotice("Sharing was not completed. The link is still available below.");
      }
    }
  }

  if (!expanded) {
    return (
      <section className="instant-room-share collapsed" aria-label="Invite people">
        <div className="instant-room-share-compact-copy">
          <span className="instant-room-kicker">Room ready</span>
          <strong>Invite people when you need them</strong>
          <span>{participantCount} {participantCount === 1 ? "participant" : "participants"} · {lifetime}</span>
          {notice && <span className="instant-room-copy-notice" role="status">{notice}</span>}
        </div>
        <div className="instant-room-share-actions">
          <button className="button primary" type="button" onClick={() => setExpanded(true)}>
            Invite people
          </button>
          <button className="button ghost" type="button" onClick={() => void copyLink()}>
            Copy link
          </button>
        </div>
      </section>
    );
  }

  return (
    <section className="instant-room-share" aria-labelledby="instant-share-title">
      <div className="instant-room-share-copy">
        <span className="instant-room-kicker">Ready to share</span>
        <div className="instant-room-share-heading">
          <h2 id="instant-share-title" ref={titleRef} tabIndex={-1}>
            Invite someone in one step
          </h2>
          <button className="button ghost compact" type="button" onClick={() => setExpanded(false)}>
            Hide invite details
          </button>
        </div>
        <p>
          Send this link or ask them to scan the QR code. They can join without
          creating an account.
        </p>
        <label htmlFor="instant-room-share-url">
          {secureLink ? "Secure room link" : "Room invite link"}
        </label>
        <div className="instant-room-link-row">
          <input
            id="instant-room-share-url"
            type="text"
            value={linkRevealed ? shareUrl : maskedShareUrl(shareUrl)}
            readOnly
            spellCheck={false}
            onFocus={(event) => event.currentTarget.select()}
          />
          <button
            className="button ghost"
            type="button"
            aria-pressed={linkRevealed}
            onClick={() => setLinkRevealed((current) => !current)}
          >
            {linkRevealed ? "Hide" : "Reveal"}
          </button>
          <button className="button primary" type="button" onClick={() => void copyLink()}>
            Copy
          </button>
          <button className="button ghost" type="button" onClick={() => void shareLink()}>
            Share
          </button>
        </div>
        <p className="instant-room-lifetime">
          {lifetime}
        </p>
        {!secureLink && (
          <p className="transport-warning" role="note">
            <strong>This invite uses unencrypted HTTP.</strong>
            <span>
              Share it only on a trusted test network and keep content
              non-sensitive. Calls and account actions require HTTPS.
            </span>
          </p>
        )}
        <p className="instant-room-continuity">
          {room.owner_kind === "registered"
            ? "Keep this tab open while hosting. Your signed-in account can reopen this room."
            : "Keep this tab open to manage the room. Create an account if you want to keep access across devices."}
        </p>
        <p className="sr-only" role="status" aria-live="polite">{notice}</p>
        {notice && <p className="instant-room-copy-notice" aria-hidden="true">{notice}</p>}
      </div>
      <QrCode value={shareUrl} label={`Scan to join ${title}`} />
    </section>
  );
}

function instantRoomLifetime(room: InstantRoom): string {
  return room.expires_at
    ? `Available until ${formatDateTime(room.expires_at)}.`
    : room.owner_kind === "registered"
      ? "Available for 24 hours after everyone leaves."
      : "Available for 1 hour after everyone leaves.";
}

function maskedShareUrl(shareUrl: string): string {
  const fragmentIndex = shareUrl.indexOf("#");
  if (fragmentIndex < 0) return shareUrl;
  return `${shareUrl.slice(0, fragmentIndex)}#guest=••••••••••••`;
}

async function copyText(value: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }

  const fallback = document.createElement("textarea");
  fallback.value = value;
  fallback.setAttribute("readonly", "");
  fallback.style.position = "fixed";
  fallback.style.opacity = "0";
  document.body.appendChild(fallback);
  fallback.select();
  const copied = document.execCommand("copy");
  fallback.remove();
  if (!copied) throw new Error("Copy was rejected");
}

function asRoomSession(
  session: Session,
  conversation: Conversation,
  capabilities: GuestCapabilities,
  room?: InstantRoom,
  shareUrl?: string
): GuestSession {
  return {
    ...session,
    conversation,
    capabilities,
    instant_room: room,
    share_url: shareUrl
  };
}

function withoutGuestConversion(session: GuestSession): GuestSession {
  return {
    ...session,
    capabilities: {
      ...session.capabilities,
      conversion_enabled: false,
      self_service_conversion: false,
      email_hint: null
    }
  };
}

function memberSessionIdentity(session: Session): string {
  return `${session.tenant.id}:${session.user.id}:${session.device.id}`;
}

const unavailableCallCapabilities: GuestCapabilities = {
  allow_audio_calls: false,
  allow_video_calls: false,
  conversion_enabled: false,
  self_service_conversion: false
};

function instantRoomError(reason: unknown): {
  message: string;
  retryAfterSeconds?: number;
} {
  if (!navigator.onLine || reason instanceof TypeError) {
    return {
      message:
        "You appear to be offline. Reconnect and try again; the same room request will be resumed."
    };
  }
  if (reason instanceof ApiError) {
    if (reason.status === 426) {
      return {
        message:
          "This action requires trusted HTTPS. Open the secure K-Comms address and try again."
      };
    }
    if (reason.status === 429) {
      return {
        message: reason.retryAfterSeconds
          ? `Room creation is rate-limited. Try again in ${reason.retryAfterSeconds} seconds.`
          : "Room creation is rate-limited. Wait a moment, then try again.",
        retryAfterSeconds: reason.retryAfterSeconds
      };
    }
    if ([404, 410, 422].includes(reason.status)) {
      return {
        message:
          "This room is unavailable. It may have expired or been revoked. Start a new room."
      };
    }
    if (reason.status >= 500) {
      return {
        message:
          "K-Comms is temporarily unavailable. Your request is safe to retry."
      };
    }
  }
  return {
    message:
      reason instanceof Error
        ? reason.message
        : "K-Comms could not open the room. Try again."
  };
}

function KCommsMark() {
  return (
    <div className="instant-room-brand" aria-label="K-Comms">
      <span aria-hidden="true">K</span>
      <strong>K-Comms</strong>
    </div>
  );
}

function EntryFieldIcon({ kind }: { kind: "person" | "room" }) {
  return <AppIcon className="instant-room-field-icon" name={kind === "person" ? "user" : "messages"} />;
}
