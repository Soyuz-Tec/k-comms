import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate } from "react-router";
import type { ApiClient } from "../../api";
import {
  ApiError,
  GuestApiClient,
  loadStoredGuestSession,
  storeGuestSession
} from "../../api";
import { useSession } from "../../app/session";
import { browserName, formatDateTime } from "../../lib/format";
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
    setSession: setAccountSession
  } = useSession();
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
  const [loading, setLoading] = useState(activeRoom === null);
  const [error, setError] = useState("");
  const [retryAt, setRetryAt] = useState<number | null>(null);
  const [retryVersion, setRetryVersion] = useState(0);
  const [leftRoom, setLeftRoom] = useState(false);
  const [clock, setClock] = useState(Date.now());
  const guestApiRef = useRef<GuestApiClient | null>(null);
  const accountSessionRef = useRef(accountSession);
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
    if (
      !memberContinuity ||
      activeRoom ||
      leftRoom ||
      !accountSession
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
    if (activeRoom || leftRoom || memberContinuity) return;
    let current = true;
    const key = instantRoomIdempotencyKey();
    setLoading(true);
    setError("");
    setRetryAt(null);

    void createInstantRoomOnce(memberApi, key, {
      ...(accountSession
        ? { display_name: accountSession.user.display_name }
        : {}),
      device: { name: browserName(), platform: "web" }
    }).then(async (result) => {
      if (!current) return;
      if (!result.share_url) {
        throw new Error(
          "The server created the room but did not return its secure share link."
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
      if (!current) return;
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
    }).catch((reason: unknown) => {
      if (!current) return;
      const display = instantRoomError(reason);
      setError(display.message);
      setRetryAt(
        display.retryAfterSeconds
          ? Date.now() + display.retryAfterSeconds * 1_000
          : null
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
    guestApi,
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
          <p>Your secure link and QR code will be ready in a moment.</p>
        </section>
      </main>
    );
  }

  if (!activeRoom || !roomApi) {
    return (
      <main className="instant-room-entry" id="main-content">
        <section className="instant-room-error" aria-labelledby="instant-room-error-title">
          <KCommsMark />
          <span className="instant-room-kicker">
            {leftRoom ? "Room closed" : "Instant room"}
          </span>
          <h1 id="instant-room-error-title">
            {leftRoom ? "Your communication session has ended" : "We could not open a room"}
          </h1>
          <p role={error ? "alert" : undefined}>
            {error ||
              "Start another room when you are ready, or sign in to your workspace."}
          </p>
          <div className="instant-room-entry-actions">
            <button
              className="button primary"
              type="button"
              disabled={retrySeconds > 0}
              onClick={() => {
                if (leftRoom) beginNewInstantRoomVisit();
                setClock(Date.now());
                setRetryAt(null);
                setLeftRoom(false);
                setRetryVersion((version) => version + 1);
              }}
            >
              {retrySeconds > 0
                ? `Try again in ${retrySeconds}s`
                : leftRoom
                  ? "Start a new room"
                  : "Try again"}
            </button>
            <Link className="button ghost" to="/sign-in">
              Sign in
            </Link>
          </div>
        </section>
      </main>
    );
  }

  const shareBanner =
    activeRoom.room && activeRoom.shareUrl ? (
      <InstantRoomSharePanel
        room={activeRoom.room}
        shareUrl={activeRoom.shareUrl}
        title={activeRoom.session.conversation.title || "Instant room"}
      />
    ) : undefined;

  return (
    <GuestShell
      api={roomApi}
      initialSession={activeRoom.session}
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
  title
}: {
  room: InstantRoom;
  shareUrl: string;
  title: string;
}) {
  const [notice, setNotice] = useState("");

  async function copyLink() {
    try {
      await copyText(shareUrl);
      setNotice("Secure link copied.");
    } catch {
      setNotice("Copy failed. Select the link and copy it manually.");
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
    <section className="instant-room-share" aria-labelledby="instant-share-title">
      <div className="instant-room-share-copy">
        <span className="instant-room-kicker">Ready to share</span>
        <h2 id="instant-share-title">Invite someone in one step</h2>
        <p>
          Send this link or ask them to scan the QR code. They can join without
          creating an account.
        </p>
        <label htmlFor="instant-room-share-url">Secure room link</label>
        <div className="instant-room-link-row">
          <input
            id="instant-room-share-url"
            type="url"
            value={shareUrl}
            readOnly
            spellCheck={false}
            onFocus={(event) => event.currentTarget.select()}
          />
          <button className="button primary" type="button" onClick={() => void copyLink()}>
            Copy
          </button>
          <button className="button ghost" type="button" onClick={() => void shareLink()}>
            Share
          </button>
        </div>
        <p className="instant-room-lifetime">
          {room.expires_at
            ? `This idle room is available until ${formatDateTime(room.expires_at)}.`
            : room.owner_kind === "registered"
              ? "When everyone leaves, this room remains available for 24 hours."
              : "When everyone leaves, this room remains available for 1 hour."}
        </p>
        <p className="sr-only" role="status" aria-live="polite">{notice}</p>
        {notice && <p className="instant-room-copy-notice" aria-hidden="true">{notice}</p>}
      </div>
      <QrCode value={shareUrl} label={`Scan to join ${title}`} />
    </section>
  );
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
