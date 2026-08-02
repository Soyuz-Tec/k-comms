import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router";
import {
  loadStoredGuestSession,
  storeGuestSession
} from "../../api";
import { useSession } from "../../app/session";
import { browserName } from "../../lib/format";
import type { GuestSession } from "../../types";
import { GuestShell } from "../guest/GuestAccessPage";
import {
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
import { InstantRoomSharePanel } from "./InstantRoomSharePanel";
import { createInstantRoomOnce, isDefinitiveRoomUnavailable } from "./instantRoomCreation";
import {
  asRoomSession,
  instantRoomError,
  memberSessionIdentity,
  unavailableCallCapabilities,
  withoutGuestConversion
} from "./instantRoomPresentation";
import {
  useInstantRoomSession,
  type ActiveRoom
} from "./useInstantRoomSession";
import { PublicLandingPage } from "./PublicLandingPage";
import {
  InstantWorkspaceDraft,
  type DraftActivationRequest
} from "./InstantWorkspaceDraft";
import { clearInstantWorkspaceDraft } from "./instantWorkspaceDraftStore";
import "./InstantRoomPage.css";
import "./PublicLandingPage.css";

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
  const restoredMemberSessionRef = useRef<string | null>(
    initialStateRef.current.member && accountSession
      ? memberSessionIdentity(accountSession)
      : null
  );
  const { guestApi, stableRoomApi } = useInstantRoomSession({
    accountSession,
    activeRoom,
    setActiveRoom,
    setError,
    setLeftRoom
  });

  useEffect(() => {
    document.title = activeRoom
      ? "Instant room | K-Comms"
      : "K-Comms | Message, meet, and create";
  }, [activeRoom]);

  useEffect(() => {
    if (!transportPolicyReady || !accountSession) return;
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

  async function activateDraftWorkspace(
    request: DraftActivationRequest
  ): Promise<boolean> {
    const chosenName =
      accountSession?.user.display_name.trim() || request.displayName.trim();
    const chosenTitle = request.roomTitle.trim();
    if (!chosenName) {
      setError("Enter the name other participants should see.");
      return false;
    }
    if (loading || retrySeconds > 0) return false;

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
        await seedDraftWorkspace(
          guestApi,
          result.conversation.id,
          request
        );
        clearInstantWorkspaceDraft();
        setActiveRoom({
          mode: "guest",
          session: guestSession,
          room: result.room,
          shareUrl: result.share_url,
          returnsToAccount: Boolean(accountSession)
        });
        return true;
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
      const memberRoomApi = new MemberRoomApi(
        memberApi,
        result.conversation.id
      );
      await seedDraftWorkspace(
        memberRoomApi,
        result.conversation.id,
        request
      );
      clearInstantWorkspaceDraft();
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
      return true;
    } catch (reason: unknown) {
      const display = instantRoomError(reason);
      setError(display.message);
      setRetryAt(
        display.retryAfterSeconds
          ? Date.now() + display.retryAfterSeconds * 1_000
          : null
      );
      return false;
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
      <PublicLandingPage
        workspace={
          <>
            {!transportPolicyReady && (
              <div className="transport-warning" role="status">
                <strong>Checking the secure connection…</strong>
                <span>Drawing stays local while K-Comms verifies this deployment.</span>
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
            {memberContinuity && error && (
              <button
                className="button ghost"
                type="button"
                onClick={() => {
                  setLoading(true);
                  setRetryVersion((version) => version + 1);
                }}
              >
                Retry existing room
              </button>
            )}
            <InstantWorkspaceDraft
              activating={loading}
              error={error}
              identityManaged={Boolean(accountSession)}
              initialDisplayName={accountSession?.user.display_name}
              retrySeconds={retrySeconds}
              onActivate={activateDraftWorkspace}
            />
          </>
        }
      />
    );
  }

  const shareBanner =
    activeRoom.room && activeRoom.shareUrl ? (
      (participantCount: number) => (
        <InstantRoomSharePanel
          placement="banner"
          room={activeRoom.room!}
          shareUrl={activeRoom.shareUrl!}
          title={activeRoom.session.conversation.title || "Instant room"}
          participantCount={participantCount}
        />
      )
    ) : undefined;
  const shareMenu =
    activeRoom.room && activeRoom.shareUrl ? (
      (participantCount: number) => (
        <InstantRoomSharePanel
          placement="menu"
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
      roomMenuInvite={shareMenu}
      whiteboardEnabled
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
          navigate("/app/", { replace: true });
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

async function seedDraftWorkspace(
  api: GuestRoomApi,
  conversationId: string,
  request: DraftActivationRequest
): Promise<void> {
  if (request.elements.length > 0) {
    await api.appendWhiteboardSceneUpdate(
      conversationId,
      request.whiteboardOperationId,
      0,
      request.elements
    );
  }

  if (request.initialMessage) {
    await api.sendMessage({
      client_message_id: request.messageClientId,
      body: request.initialMessage,
      attachment_ids: []
    });
  }
}

export { createInstantRoomOnce } from "./instantRoomCreation";
