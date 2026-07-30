import { useEffect, useRef, useState } from "react";
import { useModalDialog } from "../../components/useModalDialog";
import type { CallMediaKind } from "../../types";

type CallWorkspaceTab = "chat" | "people" | "files";

const CALL_CONTROL_LABELS_STORAGE_KEY = "k-comms.call-control-labels.v1";

function storedCallControlLabelsVisible(): boolean {
  try {
    return window.localStorage.getItem(CALL_CONTROL_LABELS_STORAGE_KEY) !== "hidden";
  } catch {
    return true;
  }
}

export function useCallPresentationState({
  callStartedAt,
  conversationId,
  joined,
  joinedKind,
  onNavigate,
  onOpenChat
}: {
  callStartedAt?: string | null;
  conversationId: string;
  joined: boolean;
  joinedKind: CallMediaKind;
  onNavigate?: (path: string) => void;
  onOpenChat?: () => void;
}) {
  const [callWorkspaceTab, setCallWorkspaceTab] =
    useState<CallWorkspaceTab>("chat");
  const [mobileWorkspaceOpen, setMobileWorkspaceOpen] = useState(false);
  const [endConfirmationOpen, setEndConfirmationOpen] = useState(false);
  const [callControlLabelsVisible, setCallControlLabelsVisible] = useState(
    storedCallControlLabelsVisible
  );
  const [labelPreferenceAnnouncement, setLabelPreferenceAnnouncement] =
    useState("");
  const [minimized, setMinimized] = useState(false);
  const [mobileCallLayout, setMobileCallLayout] = useState(
    () =>
      window.matchMedia?.("(max-width: 760px), (max-height: 560px)").matches ??
      false
  );
  const [elapsedSeconds, setElapsedSeconds] = useState(0);
  const callMenuTriggerRef = useRef<HTMLButtonElement | null>(null);
  const callMenuOpenerRef = useRef<HTMLButtonElement | null>(null);
  const wasJoinedRef = useRef(false);
  const expandedCallModal =
    joined && !minimized && (mobileCallLayout || joinedKind === "video");

  function openMobileCallMenu(opener: HTMLButtonElement) {
    callMenuOpenerRef.current = opener;
    setMobileWorkspaceOpen(true);
  }

  function closeMobileCallMenu() {
    const opener = callMenuOpenerRef.current ?? callMenuTriggerRef.current;
    setMobileWorkspaceOpen(false);
    window.requestAnimationFrame(() => {
      if (opener?.isConnected && !opener.inert) {
        opener.focus({ preventScroll: true });
      }
      callMenuOpenerRef.current = null;
    });
  }

  function toggleCallControlLabels() {
    setCallControlLabelsVisible((visible) => {
      const next = !visible;
      try {
        window.localStorage.setItem(
          CALL_CONTROL_LABELS_STORAGE_KEY,
          next ? "visible" : "hidden"
        );
      } catch {
        // A blocked preference store must not interfere with call controls.
      }
      setLabelPreferenceAnnouncement(
        next ? "Control labels shown" : "Control labels hidden"
      );
      return next;
    });
  }

  const callWorkspaceRef = useModalDialog(
    closeMobileCallMenu,
    mobileCallLayout && mobileWorkspaceOpen && !minimized
  );
  const callDockRef = useModalDialog(() => {
    if (mobileWorkspaceOpen) {
      closeMobileCallMenu();
      return;
    }
    setMinimized(true);
  }, expandedCallModal);
  const endConfirmationRef = useModalDialog(
    () => setEndConfirmationOpen(false),
    endConfirmationOpen
  );

  function openConversationChat() {
    setCallWorkspaceTab("chat");
    setMobileWorkspaceOpen(false);
    setMinimized(true);
    if (onNavigate) {
      onNavigate(`/app/?conversation=${encodeURIComponent(conversationId)}`);
    } else {
      onOpenChat?.();
    }
  }

  useEffect(() => {
    if (!window.matchMedia) return;
    const query = window.matchMedia(
      "(max-width: 760px), (max-height: 560px)"
    );
    const update = () => setMobileCallLayout(query.matches);
    update();
    query.addEventListener?.("change", update);
    return () => query.removeEventListener?.("change", update);
  }, []);

  useEffect(() => {
    if (!joined) {
      wasJoinedRef.current = false;
      setMinimized(false);
      setElapsedSeconds(0);
      return;
    }
    if (wasJoinedRef.current) return;
    wasJoinedRef.current = true;
    setMinimized(joinedKind === "audio" && !mobileCallLayout);
    const frame = window.requestAnimationFrame(() => {
      callDockRef.current
        ?.querySelector<HTMLElement>("[data-call-focus]")
        ?.focus({ preventScroll: true });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [joined, joinedKind, mobileCallLayout]);

  useEffect(() => {
    if (joined && joinedKind === "audio" && mobileCallLayout) {
      setMinimized(false);
    }
  }, [joined, joinedKind, mobileCallLayout]);

  useEffect(() => {
    if (!joined) return;
    const startedAt = callStartedAt ? Date.parse(callStartedAt) : Date.now();
    const update = () =>
      setElapsedSeconds(
        Math.max(0, Math.floor((Date.now() - startedAt) / 1_000))
      );
    update();
    const timer = window.setInterval(update, 1_000);
    return () => window.clearInterval(timer);
  }, [callStartedAt, joined]);

  return {
    callControlLabelsVisible,
    callDockRef,
    callMenuTriggerRef,
    callWorkspaceRef,
    callWorkspaceTab,
    closeMobileCallMenu,
    elapsedSeconds,
    endConfirmationOpen,
    endConfirmationRef,
    expandedCallModal,
    labelPreferenceAnnouncement,
    minimized,
    mobileCallLayout,
    mobileWorkspaceOpen,
    openConversationChat,
    openMobileCallMenu,
    setCallWorkspaceTab,
    setEndConfirmationOpen,
    setMinimized,
    setMobileWorkspaceOpen,
    toggleCallControlLabels
  };
}
