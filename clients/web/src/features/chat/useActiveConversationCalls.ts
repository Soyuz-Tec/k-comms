import { useCallback, useEffect, useRef, useState } from "react";
import type { ApiClient } from "../../api";

const pollIntervalMs = 15_000;
const pageSize = 100;

const emptyConversationIds: ReadonlySet<string> = new Set<string>();

/**
 * Conversation ids with a call running right now, so the inbox can say which
 * rooms are live before you open them. A failed poll keeps the last known set
 * rather than clearing the badges, because a transient network blip is not
 * evidence that the calls ended.
 */
export function useActiveConversationCalls(api: ApiClient): ReadonlySet<string> {
  const [conversationIds, setConversationIds] =
    useState<ReadonlySet<string>>(emptyConversationIds);
  const mounted = useRef(true);

  const load = useCallback(async () => {
    try {
      const page = await api.calls({ scope: "active", limit: pageSize });
      if (!mounted.current) return;
      const live = new Set(
        page.data
          .filter((call) => call.status === "active")
          .map((call) => call.conversation_id)
      );
      setConversationIds((current) =>
        sameMembers(current, live) ? current : live
      );
    } catch {
      // Keep the last known live rooms; the next poll re-establishes truth.
    }
  }, [api]);

  useEffect(() => {
    mounted.current = true;
    void load();
    const refresh = () => {
      if (document.visibilityState !== "visible") return;
      void load();
    };
    const timer = window.setInterval(refresh, pollIntervalMs);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      mounted.current = false;
      window.clearInterval(timer);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [load]);

  return conversationIds;
}

function sameMembers(left: ReadonlySet<string>, right: ReadonlySet<string>): boolean {
  if (left.size !== right.size) return false;
  for (const value of left) {
    if (!right.has(value)) return false;
  }
  return true;
}
