import {
  useCallback,
  useEffect,
  useRef,
  useState
} from "react";
import type { useSearchParams } from "react-router";
import type { Conversation } from "../../types";

type SetSearchParams = ReturnType<typeof useSearchParams>[1];

interface UseChatNavigationOptions {
  activeConversation: Conversation | null;
  activeConversationId: string | null;
  conversations: Conversation[];
  setSearchParams: SetSearchParams;
  workspaceLoading: boolean;
  closeConversationPanels: () => void;
}

export function useChatNavigation({
  activeConversation,
  activeConversationId,
  conversations,
  setSearchParams,
  workspaceLoading,
  closeConversationPanels
}: UseChatNavigationOptions) {
  const [isMobile, setIsMobile] = useState(
    () => window.matchMedia?.("(max-width: 760px)").matches ?? false
  );
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

  useEffect(() => {
    if (workspaceLoading || conversations.length === 0 || isMobile) return;
    if (
      !activeConversationId ||
      !conversations.some(({ id }) => id === activeConversationId)
    ) {
      setSearchParams(
        { conversation: conversations[0]?.id || "" },
        { replace: true }
      );
    }
  }, [
    activeConversationId,
    conversations,
    isMobile,
    setSearchParams,
    workspaceLoading
  ]);

  useEffect(() => {
    const previousConversationId = previousMobileConversationRef.current;
    previousMobileConversationRef.current = activeConversation?.id || null;
    if (!isMobile || mobilePane !== "list") return;

    const conversationId =
      mobileListFocusConversationRef.current || previousConversationId;
    if (!conversationId) return;
    const frame = window.requestAnimationFrame(() => {
      const target = conversationButtonRefs.current.get(conversationId);
      if (!target) return;
      target.focus({ preventScroll: true });
      target.scrollIntoView({ block: "nearest" });
      mobileListFocusConversationRef.current = null;
    });
    return () => window.cancelAnimationFrame(frame);
  }, [activeConversation?.id, isMobile, mobilePane]);

  useEffect(() => {
    if (!isMobile || mobilePane !== "messages") return;
    const frame = window.requestAnimationFrame(() =>
      mobileBackRef.current?.focus({ preventScroll: true })
    );
    return () => window.cancelAnimationFrame(frame);
  }, [activeConversation?.id, isMobile, mobilePane]);

  useEffect(() => {
    if (!focusComposerAfterDirectRef.current || !activeConversationId) return;
    const frame = window.requestAnimationFrame(() => {
      const composer = document.getElementById("message-composer");
      if (!(composer instanceof HTMLTextAreaElement)) return;
      composer.focus({ preventScroll: true });
      focusComposerAfterDirectRef.current = false;
    });
    return () => window.cancelAnimationFrame(frame);
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
    conversationButtonRefs,
    focusComposerAfterDirect,
    isMobile,
    mobileBackRef,
    mobilePane,
    selectConversation,
    showConversationList
  };
}
