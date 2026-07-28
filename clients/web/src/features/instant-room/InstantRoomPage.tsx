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
import { useModalDialog } from "../../components/useModalDialog";
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
  const [displayNameError, setDisplayNameError] = useState("");
  const [roomTitle, setRoomTitle] = useState("");
  const displayNameInputRef = useRef<HTMLInputElement>(null);
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
    if (!chosenName) {
      setDisplayNameError("Enter your display name to continue.");
      displayNameInputRef.current?.focus();
      return;
    }
    if (loading || retrySeconds > 0) return;

    if (leftRoom || memberContinuity) {
      clearMemberInstantRoomContinuity();
      beginNewInstantRoomVisit();
      setMemberContinuity(null);
      setLeftRoom(false);
    }

    const key = instantRoomIdempotencyKey();
    setLoading(true);
    setError("");
    setDisplayNameError("");
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

  if (loading && !activeRoom && memberContinuity) {
    return (
      <main className="instant-room-entry" id="main-content" aria-busy="true">
        <section className="instant-room-loading" aria-labelledby="instant-room-title">
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
            aria-busy={loading}
            noValidate
          >
            {accountSession ? (
              <p className="instant-room-account-identity">
                <span>Starting as</span>
                <strong>{accountSession.user.display_name}</strong>
                <small>Managed by your workspace profile</small>
              </p>
            ) : (
              <div className="field">
                <label
                  className="instant-room-field-label"
                  htmlFor="instant-room-display-name"
                >
                  Your display name
                  <span className="required" aria-hidden="true">Required</span>
                </label>
                <input
                  ref={displayNameInputRef}
                  id="instant-room-display-name"
                  name="display_name"
                  type="text"
                  minLength={1}
                  maxLength={120}
                  autoComplete="name"
                  value={displayName}
                  onChange={(event) => {
                    setDisplayName(event.target.value);
                    if (event.target.value.trim()) setDisplayNameError("");
                  }}
                  placeholder="Your name"
                  aria-describedby={[
                    "instant-room-display-name-help",
                    displayNameError
                      ? "instant-room-display-name-error"
                      : ""
                  ].filter(Boolean).join(" ")}
                  aria-invalid={Boolean(displayNameError)}
                  disabled={loading}
                  required
                />
                <small id="instant-room-display-name-help">
                  Visible to everyone in the room.
                </small>
                {displayNameError && (
                  <small
                    className="instant-room-field-error"
                    id="instant-room-display-name-error"
                    role="alert"
                  >
                    {displayNameError}
                  </small>
                )}
              </div>
            )}
            <div className="field">
              <label
                className="instant-room-field-label"
                htmlFor="instant-room-title"
              >
                Room name <span className="optional">Optional</span>
              </label>
              <input
                id="instant-room-title"
                name="title"
                type="text"
                maxLength={160}
                autoComplete="off"
                value={roomTitle}
                onChange={(event) => setRoomTitle(event.target.value)}
                placeholder="Daily check-in"
                aria-describedby="instant-room-title-help"
                disabled={loading}
              />
              <small id="instant-room-title-help">
                Defaults to “Instant room”.
              </small>
            </div>
            <button
              className="button primary full"
              type="submit"
              aria-disabled={loading || retrySeconds > 0}
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
          <span className="sr-only" role="status" aria-live="polite">
            {loading ? "Opening your room. Please wait." : ""}
          </span>
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
  const [expanded, setExpanded] = useState(false);
  const [linkRevealed, setLinkRevealed] = useState(false);
  const [showQr, setShowQr] = useState(false);
  const secureLink = isEncryptedUrl(shareUrl);
  const lifetime = instantRoomLifetime(room);
  const dialogRef = useModalDialog(closeDetails, expanded);

  useEffect(() => {
    if (participantCount > 1) {
      setExpanded(false);
      setLinkRevealed(false);
      setShowQr(false);
    }
  }, [participantCount]);

  function closeDetails() {
    setExpanded(false);
    setLinkRevealed(false);
    setShowQr(false);
  }

  async function copyLink() {
    try {
      await copyText(shareUrl);
      setNotice(`${secureLink ? "Secure link" : "Invite link"} copied.`);
      closeDetails();
    } catch {
      setLinkRevealed(true);
      setShowQr(false);
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
      closeDetails();
    } catch (reason: unknown) {
      if (
        !(reason instanceof DOMException) ||
        reason.name !== "AbortError"
      ) {
        setNotice("Sharing was not completed. The link is still available below.");
      }
    }
  }

  return (
    <>
      <section className="instant-room-share collapsed" aria-label="Invite people">
        <div className="instant-room-share-compact-copy">
          <strong>Invite people</strong>
          <span>{participantCount} {participantCount === 1 ? "participant" : "participants"}</span>
          {notice && <span className="instant-room-copy-notice" role="status">{notice}</span>}
        </div>
        <div className="instant-room-share-actions">
          <button
            className="button primary"
            type="button"
            aria-label="Invite people"
            aria-expanded={expanded}
            aria-controls="instant-room-invite-dialog"
            onClick={() => setExpanded(true)}
          >
            Invite
          </button>
          <button
            className="button ghost"
            type="button"
            aria-label="Copy invite link"
            onClick={() => void copyLink()}
          >
            Copy
          </button>
        </div>
      </section>

      {expanded && (
        <div
          className="instant-room-invite-backdrop"
          onPointerDown={(event) => {
            if (event.currentTarget === event.target) closeDetails();
          }}
        >
          <section
            ref={dialogRef}
            className={`instant-room-share instant-room-invite-dialog${
              showQr ? " has-qr" : ""
            }`}
            id="instant-room-invite-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="instant-share-title"
          >
            <div className="instant-room-share-copy">
              <span className="instant-room-kicker">Ready to share</span>
              <div className="instant-room-share-heading">
                <h2 id="instant-share-title" tabIndex={-1} data-initial-focus>
                  Invite someone
                </h2>
                <button className="button ghost compact" type="button" onClick={closeDetails}>
                  Hide invite details
                </button>
              </div>
              <p className="instant-room-share-guidance">
                Show the QR code only when someone is ready to scan it.
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
              <button
                className="button ghost instant-room-qr-toggle"
                type="button"
                aria-expanded={showQr}
                aria-controls="instant-room-qr-panel"
                onClick={() => setShowQr((current) => !current)}
              >
                {showQr ? "Hide QR code" : "Show QR code"}
              </button>
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
            {showQr && (
              <div className="instant-room-qr-panel" id="instant-room-qr-panel">
                <QrCode value={shareUrl} label={`Scan to join ${title}`} />
                <p>Anyone who scans this code can use the room invite.</p>
              </div>
            )}
          </section>
        </div>
      )}
    </>
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
