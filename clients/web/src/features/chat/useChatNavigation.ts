import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState
} from "react";
import type { useSearchParams } from "react-router";
import type { Conversation } from "../../types";

type SetSearchParams = ReturnType<typeof useSearchParams>[1];

interface UseChatNavigationOptions {
  requestedConversationId: string | null;
  conversations: Conversation[];
  setSearchParams: SetSearchParams;
  workspaceLoading: boolean;
  closeConversationPanels: () => void;
}

export function useChatNavigation({
  requestedConversationId,
  conversations,
  setSearchParams,
  workspaceLoading,
  closeConversationPanels
}: UseChatNavigationOptions) {
  const [isMobile, setIsMobile] = useState(
    () => window.matchMedia?.("(max-width: 760px)").matches ?? false
  );
  const [defaultConversationId, setDefaultConversationId] = useState<string | null>(null);
  // The default is presentation state, not a navigation. A passive redirect
  // from a cold route can run after a newer notification navigation and erase
  // its message parameter before React commits that destination.
  const activeConversationId = requestedConversationId || (
    !isMobile && !workspaceLoading
      ? conversations.find(({ id }) => id === defaultConversationId)?.id ?? conversations[0]?.id ?? null
      : null
  );
  const activeConversation = useMemo(
    () => conversations.find(({ id }) => id === activeConversationId) ?? null,
    [activeConversationId, conversations]
  );
  useEffect(() => {
    if (!requestedConversationId && activeConversationId) setDefaultConversationId(activeConversationId);
  }, [activeConversationId, requestedConversationId]);
  const conversationButtonRefs = useRef(
    new Map<string, HTMLButtonElement>()
  );
  const mobileBackRef = useRef<HTMLButtonElement | null>(null);
  const mobileListFocusConversationRef = useRef<string | null>(null);
  const previousMobileConversationRef = useRef<string | null>(null);
  const focusComposerAfterDirectRef = useRef(false);
  const mobilePane = isMobile && !activeConversation ? "list" : "messages";

  useEffect(() => {
    if (!window.matchMedia) return;
    const query = window.matchMedia("(max-width: 760px)");
    const changed = () => setIsMobile(query.matches);
    changed();
    query.addEventListener("change", changed);
    return () => query.removeEventListener("change", changed);
  }, []);

  useLayoutEffect(() => {
    const previousConversationId = previousMobileConversationRef.current;
    previousMobileConversationRef.current = activeConversation?.id || null;
    if (!isMobile || mobilePane !== "list") return;

    const conversationId =
      mobileListFocusConversationRef.current || previousConversationId;
    if (!conversationId) return;
    mobileListFocusConversationRef.current = null;
    return scheduleNavigationFocus(() => {
      const target = conversationButtonRefs.current.get(conversationId);
      if (!target) return;
      target.focus({ preventScroll: true });
      target.scrollIntoView({ block: "nearest" });
    });
  }, [activeConversation?.id, isMobile, mobilePane]);

  useLayoutEffect(() => {
    if (!isMobile || mobilePane !== "messages" || focusComposerAfterDirectRef.current) return;
    return scheduleNavigationFocus(() =>
      mobileBackRef.current?.focus({ preventScroll: true })
    );
  }, [activeConversation?.id, isMobile, mobilePane]);

  useLayoutEffect(() => {
    if (!focusComposerAfterDirectRef.current || !activeConversationId) return;
    focusComposerAfterDirectRef.current = false;
    return scheduleNavigationFocus(() => {
      const composer = document.getElementById("message-composer");
      if (!(composer instanceof HTMLTextAreaElement)) return;
      composer.focus({ preventScroll: true });
    });
  }, [activeConversationId, mobilePane]);

  const selectConversation = useCallback(
    (id: string) => {
      setSearchParams({ conversation: id });
      closeConversationPanels();
    },
    [closeConversationPanels, setSearchParams]
  );

  const showConversationList = useCallback(() => {
    mobileListFocusConversationRef.current = activeConversation?.id || null;
    setSearchParams({}, { replace: true });
    closeConversationPanels();
  }, [activeConversation?.id, closeConversationPanels, setSearchParams]);

  const focusComposerAfterDirect = useCallback(() => {
    focusComposerAfterDirectRef.current = true;
  }, []);

  return {
    activeConversation,
    activeConversationId,
    conversationButtonRefs,
    focusComposerAfterDirect,
    isMobile,
    mobileBackRef,
    mobilePane,
    selectConversation,
    showConversationList
  };
}

function scheduleNavigationFocus(focus: () => void): () => void {
  // Contextual layout effects schedule before generic route orientation. Any
  // later user interaction owns focus, even before this frame gets CPU time.
  let frame: number | null = null;
  const stop = () => {
    if (frame !== null) window.cancelAnimationFrame(frame);
    frame = null;
    document.removeEventListener("focusin", stop, true);
    document.removeEventListener("keydown", stop, true);
    document.removeEventListener("pointerdown", stop, true);
  };
  document.addEventListener("focusin", stop, true);
  document.addEventListener("keydown", stop, true);
  document.addEventListener("pointerdown", stop, true);
  frame = window.requestAnimationFrame(() => {
    stop();
    focus();
  });
  return stop;
}
