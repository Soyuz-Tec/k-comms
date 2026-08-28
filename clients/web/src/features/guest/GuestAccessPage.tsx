import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useNavigate } from "react-router";
import {
  GuestApiClient,
  loadStoredGuestSession,
  storeGuestSession
} from "../../api";
import { useSession } from "../../app/session";
import type { GuestSession } from "../../types";
import {
  guestTokenFromFragment,
  scrubGuestTokenFragment
} from "./guestLink";
import {
  DelegatingRoomApi,
  MemberRoomApi
} from "./roomApi";
import {
  beginNewInstantRoomVisit
} from "../instant-room/idempotency";
import { InstantRoomSharePanel } from "../instant-room/InstantRoomSharePanel";
import {
  capturedInstantRoomShareUrl,
  clearMemberInstantRoomContinuity,
  loadMemberInstantRoomContinuity,
  type MemberInstantRoomContinuity,
  storeMemberInstantRoomContinuity
} from "../instant-room/memberContinuity";
import { GuestJoin } from "./GuestJoin";
import { GuestShell } from "./GuestShell";
import {
  callReadinessHostPath,
  clearCallReadinessSearch,
  safeCallReadinessMode
} from "../calls/callReadinessNavigation";
import {
  isDefinitiveRoomUnavailable,
  memberSessionIdentity,
  withoutGuestConversion
} from "./guestAccessPolicy";
import "./GuestAccess.css";

const apiBase = import.meta.env.VITE_API_BASE_URL || "";

export { GuestShell } from "./GuestShell";
export { loadGuestMessageCatchUp } from "./guestMessageCatchUp";

export function GuestAccessPage() {
  const navigate = useNavigate();
  const {
    api: accountApi,
    session: accountSession,
    setSession: setAccountSession,
    transportPolicyReady,
    accountActionsAllowed,
    mediaActionsAllowed,
    serviceStatus
  } = useSession();
  const secureAccountActionsAllowed =
    transportPolicyReady && accountActionsAllowed;
  const secureMediaActionsAllowed =
    transportPolicyReady && mediaActionsAllowed;
  const [token] = useState(() => guestTokenFromFragment());
  const [initialCallReadinessMode, setInitialCallReadinessMode] = useState(() => {
    const search = new URLSearchParams(window.location.search);
    return search.get("call") === "audio"
      ? safeCallReadinessMode(search.get("call_readiness"))
      : null;
  });
  const [entryShareUrl] = useState(() =>
    token ? capturedInstantRoomShareUrl(token) : null
  );
  const [accessEnded, setAccessEnded] = useState(false);
  const [guestSession, setGuestSessionState] = useState<GuestSession | null>(
    () => {
      if (token) {
        storeGuestSession(null);
        return null;
      }

      return loadStoredGuestSession();
    }
  );
  const [continuedSession, setContinuedSession] =
    useState<GuestSession | null>(null);
  const [memberContinuity, setMemberContinuity] =
    useState<MemberInstantRoomContinuity | null>(() =>
      !token && accountSession
        ? loadMemberInstantRoomContinuity(accountSession)
        : null
    );
  const [continuityError, setContinuityError] = useState("");
  const [continuityRetry, setContinuityRetry] = useState(0);
  const restoredMemberSessionRef = useRef<string | null>(
    memberContinuity && accountSession
      ? memberSessionIdentity(accountSession)
      : null
  );
  const apiRef = useRef<GuestApiClient | null>(null);

  const setGuestSession = useCallback((
    session: GuestSession | null,
    reason?: "access_ended" | "logout"
  ) => {
    if (reason === "access_ended") {
      setAccessEnded(true);
    } else if (session) {
      setAccessEnded(false);
    }
    storeGuestSession(session);
    setGuestSessionState(session);
  }, []);

  useLayoutEffect(() => {
    if (token) {
      clearMemberInstantRoomContinuity();
      scrubGuestTokenFragment();
    }
  }, [token]);

  useEffect(() => {
    if (
      !transportPolicyReady ||
      !accountSession ||
      token ||
      guestSession ||
      continuedSession ||
      memberContinuity
    ) {
      return;
    }
    const identity = memberSessionIdentity(accountSession);
    if (restoredMemberSessionRef.current === identity) return;
    restoredMemberSessionRef.current = identity;
    const continuity = loadMemberInstantRoomContinuity(accountSession);
    if (continuity) setMemberContinuity(continuity);
  }, [
    accountSession,
    continuedSession,
    guestSession,
    memberContinuity,
    token,
    transportPolicyReady
  ]);

  useEffect(() => {
    if (!accountSession && memberContinuity) {
      clearMemberInstantRoomContinuity();
      beginNewInstantRoomVisit();
      setMemberContinuity(null);
      setContinuityError("");
      return;
    }
    if (!memberContinuity || !accountSession || token || guestSession) return;
    let current = true;
    setContinuityError("");
    void accountApi.conversation(memberContinuity.conversation.id)
      .then((conversation) => {
        if (!current) return;
        if (
          conversation.id !== memberContinuity.conversation.id ||
          conversation.archived_at
        ) {
          clearMemberInstantRoomContinuity();
          setMemberContinuity(null);
          return;
        }
        navigate(
          `/app/?conversation=${encodeURIComponent(conversation.id)}`,
          { replace: true }
        );
        setMemberContinuity(null);
      })
      .catch((reason: unknown) => {
        if (!current) return;
        if (isDefinitiveRoomUnavailable(reason)) {
          clearMemberInstantRoomContinuity();
          setMemberContinuity(null);
          return;
        }
        setContinuityError(
          "K-Comms could not confirm this room. Retry to reopen the same conversation."
        );
      });
    return () => {
      current = false;
    };
  }, [
    accountApi,
    accountSession,
    continuityRetry,
    guestSession,
    memberContinuity,
    navigate,
    token
  ]);

  if (!apiRef.current) {
    apiRef.current = new GuestApiClient(apiBase, guestSession, setGuestSession);
  }
  const api = apiRef.current;
  api.setSession(guestSession);
  const roomApiRef = useRef<DelegatingRoomApi | null>(null);
  if (!roomApiRef.current) roomApiRef.current = new DelegatingRoomApi(api);
  const roomApi = roomApiRef.current;
  roomApi.setDelegate(
    continuedSession
      ? new MemberRoomApi(accountApi, continuedSession.conversation.id)
      : api
  );
  const activeRoomSession =
    continuedSession ||
    (guestSession && accountSession
      ? withoutGuestConversion(guestSession)
      : guestSession);

  if (memberContinuity && !activeRoomSession) {
    return (
      <main className="guest-entry" id="main-content">
        <section
          className="guest-entry-card"
          aria-labelledby="member-room-recovery-title"
        >
          <span className="guest-badge">Member room</span>
          <h1 id="member-room-recovery-title">Reopening your conversation…</h1>
          {continuityError ? (
            <>
              <p className="form-error" role="alert">{continuityError}</p>
              <button
                className="button primary full"
                type="button"
                onClick={() => setContinuityRetry((value) => value + 1)}
              >
                Retry
              </button>
            </>
          ) : (
            <p role="status">Confirming the room with your signed-in account.</p>
          )}
        </section>
      </main>
    );
  }

  if (activeRoomSession) {
    const sharePanel =
      activeRoomSession.instant_room && activeRoomSession.share_url
        ? (placement: "banner" | "menu") => (participantCount: number) => (
            <InstantRoomSharePanel
              placement={placement}
              room={activeRoomSession.instant_room!}
              shareUrl={activeRoomSession.share_url!}
              title={activeRoomSession.conversation.title || "Instant room"}
              participantCount={participantCount}
            />
          )
        : null;

    return (
      <GuestShell
        api={roomApi}
        initialSession={activeRoomSession}
        accountActionsAllowed={secureAccountActionsAllowed}
        mediaActionsAllowed={secureMediaActionsAllowed}
        serviceStatus={serviceStatus}
        identityLabel={
          activeRoomSession.user.account_type === "guest" ? "Guest" : "Member"
        }
        initialCallOnEntry={initialCallReadinessMode ? "audio" : null}
        initialCallReadinessMode={initialCallReadinessMode}
        onInitialCallConsumed={() => {
          setInitialCallReadinessMode(null);
          const url = new URL(window.location.href);
          url.search = clearCallReadinessSearch(url.searchParams).toString();
          window.history.replaceState(window.history.state, "", url);
        }}
        roomBanner={sharePanel?.("banner")}
        roomMenuInvite={sharePanel?.("menu")}
        whiteboardEnabled={Boolean(activeRoomSession.instant_room)}
        onAccessEnded={() => {
          clearMemberInstantRoomContinuity();
          if (continuedSession || accountSession) {
            setAccessEnded(false);
            setGuestSession(null);
            setContinuedSession(null);
            navigate("/app/", { replace: true });
            return;
          }
          setGuestSession(null, "access_ended");
        }}
        onLeave={() => {
          clearMemberInstantRoomContinuity();
          if (continuedSession || accountSession) {
            setAccessEnded(false);
            setGuestSession(null);
            if (continuedSession) {
              navigate(
                `/app/?conversation=${encodeURIComponent(
                  continuedSession.conversation.id
                )}`,
                { replace: true }
              );
              return;
            }
            navigate(
              "/app/",
              { replace: true }
            );
            return;
          }
          setAccessEnded(false);
          setGuestSession(null);
        }}
        onConverted={(session, conversation) => {
          if (accountSession && !continuedSession) {
            return;
          }
          if (
            guestSession?.capabilities.self_service_conversion === true
          ) {
            const registeredRoom = guestSession.instant_room
              ? {
                  ...guestSession.instant_room,
                  ...(guestSession.instant_room.owner_user_id ===
                  guestSession.user.id
                    ? { owner_kind: "registered" as const }
                    : {})
                }
              : undefined;
            const continued: GuestSession = {
              ...session,
              conversation,
              capabilities: {
                ...guestSession.capabilities,
                conversion_enabled: false,
                self_service_conversion: false
              },
              instant_room: registeredRoom,
              share_url: guestSession.share_url
            };
            if (registeredRoom && guestSession.share_url) {
              storeMemberInstantRoomContinuity(session, {
                room: registeredRoom,
                conversation,
                share_url: guestSession.share_url
              });
            }
            setGuestSession(null);
            setAccountSession(session);
            setContinuedSession(continued);
            return;
          }
          setGuestSession(null);
          setAccountSession(session);
          navigate(`/app/?conversation=${encodeURIComponent(conversation.id)}`, {
            replace: true
          });
        }}
      />
    );
  }

  return (
      <GuestJoin
        api={api}
        accountApi={accountApi}
        accountSession={accountSession}
        accountActionsAllowed={secureAccountActionsAllowed}
        mediaActionsAllowed={secureMediaActionsAllowed}
        token={token}
        accessEnded={accessEnded}
        onJoined={(session) => {
          const joinedSession =
            session.instant_room && entryShareUrl
              ? { ...session, share_url: entryShareUrl }
              : session;
          setGuestSession(
            accountSession
              ? withoutGuestConversion(joinedSession)
              : joinedSession
          );
        }}
        onAccountJoined={(result) => {
          if (accountSession && entryShareUrl) {
            storeMemberInstantRoomContinuity(accountSession, {
              room: result.room,
              conversation: result.conversation,
              share_url: entryShareUrl
            });
          }
          navigate(
            initialCallReadinessMode
              ? callReadinessHostPath(result.conversation.id)
              : `/app/?conversation=${encodeURIComponent(result.conversation.id)}`,
            { replace: true }
          );
        }}
      />
  );
}
