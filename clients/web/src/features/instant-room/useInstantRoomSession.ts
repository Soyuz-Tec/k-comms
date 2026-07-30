import {
  useCallback,
  useRef,
  type Dispatch,
  type SetStateAction
} from "react";
import {
  GuestApiClient,
  storeGuestSession
} from "../../api";
import type {
  GuestSession,
  InstantRoom,
  Session
} from "../../types";
import { DelegatingRoomApi } from "../guest/roomApi";
import { withoutGuestConversion } from "./instantRoomPresentation";

const apiBase = import.meta.env.VITE_API_BASE_URL || "";

export interface ActiveRoom {
  mode: "guest" | "member";
  session: GuestSession;
  room?: InstantRoom;
  shareUrl?: string;
  returnsToAccount?: boolean;
}

interface UseInstantRoomSessionOptions {
  accountSession: Session | null;
  activeRoom: ActiveRoom | null;
  setActiveRoom: Dispatch<SetStateAction<ActiveRoom | null>>;
  setError: Dispatch<SetStateAction<string>>;
  setLeftRoom: Dispatch<SetStateAction<boolean>>;
}

export function useInstantRoomSession({
  accountSession,
  activeRoom,
  setActiveRoom,
  setError,
  setLeftRoom
}: UseInstantRoomSessionOptions) {
  const guestApiRef = useRef<GuestApiClient | null>(null);
  const stableRoomApiRef = useRef<DelegatingRoomApi | null>(null);
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
  }, [setActiveRoom, setError, setLeftRoom]);

  if (!guestApiRef.current) {
    guestApiRef.current = new GuestApiClient(
      apiBase,
      activeRoom?.mode === "guest" ? activeRoom.session : null,
      updateGuestSession
    );
  }
  const guestApi = guestApiRef.current;
  guestApi.setSession(activeRoom?.mode === "guest" ? activeRoom.session : null);

  if (!stableRoomApiRef.current) {
    stableRoomApiRef.current = new DelegatingRoomApi(guestApi);
  }

  return {
    guestApi,
    stableRoomApi: stableRoomApiRef.current
  };
}
