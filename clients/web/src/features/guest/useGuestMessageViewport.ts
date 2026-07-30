import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState
} from "react";
import type { GuestRoomApi } from "./roomApi";

export function useGuestMessageViewport({
  api,
  loading
}: {
  api: GuestRoomApi;
  loading: boolean;
}) {
  const [isNearBottom, setIsNearBottom] = useState(true);
  const [newMessageCount, setNewMessageCount] = useState(0);
  const nearBottomRef = useRef(true);
  const scrollRequestRef = useRef<ScrollBehavior | null>("auto");
  const latestSequenceRef = useRef(0);
  const lastMarkedReadRef = useRef(0);
  const messageScrollRef = useRef<HTMLDivElement | null>(null);
  const composerRef = useRef<HTMLTextAreaElement | null>(null);

  const markLatestRead = useCallback(() => {
    const latest = latestSequenceRef.current;
    if (
      document.visibilityState !== "visible" ||
      !nearBottomRef.current ||
      latest <= 0 ||
      latest <= lastMarkedReadRef.current
    ) {
      return;
    }

    lastMarkedReadRef.current = latest;
    void api.markRead(latest).catch(() => {
      lastMarkedReadRef.current = 0;
    });
  }, [api, latestSequenceRef]);

  useLayoutEffect(() => {
    const behavior = scrollRequestRef.current;
    const scroll = messageScrollRef.current;
    if (loading || !behavior || !scroll) return;

    scrollRequestRef.current = null;
    scroll.scrollTo?.({ top: scroll.scrollHeight, behavior });
    scroll.scrollTop = scroll.scrollHeight;
    nearBottomRef.current = true;
    setIsNearBottom(true);
    setNewMessageCount(0);
    markLatestRead();
  });

  useEffect(() => {
    function visibilityChanged() {
      if (document.visibilityState === "visible") markLatestRead();
    }
    document.addEventListener("visibilitychange", visibilityChanged);
    return () =>
      document.removeEventListener("visibilitychange", visibilityChanged);
  }, [markLatestRead]);

  function messageScrollChanged() {
    const scroll = messageScrollRef.current;
    if (!scroll) return;
    const nearBottom =
      scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight <= 96;
    nearBottomRef.current = nearBottom;
    setIsNearBottom(nearBottom);
    if (nearBottom) {
      setNewMessageCount(0);
      markLatestRead();
    }
  }

  function jumpToLatest() {
    const scroll = messageScrollRef.current;
    if (!scroll) return;
    scroll.scrollTo?.({ top: scroll.scrollHeight, behavior: "smooth" });
    scroll.scrollTop = scroll.scrollHeight;
    nearBottomRef.current = true;
    setIsNearBottom(true);
    setNewMessageCount(0);
    markLatestRead();
    composerRef.current?.focus();
  }

  return {
    composerRef,
    isNearBottom,
    jumpToLatest,
    latestSequenceRef,
    messageScrollChanged,
    messageScrollRef,
    nearBottomRef,
    newMessageCount,
    scrollRequestRef,
    setNewMessageCount
  };
}
