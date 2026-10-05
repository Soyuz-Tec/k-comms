import { createContext, useCallback, useContext, useMemo, useState } from "react";
import type { ReactNode } from "react";
import { useLocation, useNavigate, useNavigationType } from "react-router";

interface KnownHistory {
  keys: string[];
  index: number;
  browserIndex?: number;
}

export interface RouterHistoryNavigation {
  canGoBack: boolean;
  canGoForward: boolean;
  onBack: () => void;
  onForward: () => void;
}

const RouterHistoryContext = createContext<RouterHistoryNavigation | null>(null);
const retainedEntries = 100;

function browserRouterIndex(): number | undefined {
  const value: unknown = typeof window === "undefined" ? undefined : window.history.state?.idx;
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
}

/** Only entries observed by this mounted router can enable app history controls. */
export function RouterHistoryProvider({ children, trackBrowserIndex = false }: { children: ReactNode; trackBrowserIndex?: boolean }) {
  const { key } = useLocation();
  const navigationType = useNavigationType();
  const navigate = useNavigate();
  const browserIndex = trackBrowserIndex ? browserRouterIndex() : undefined;
  const [recorded, setRecorded] = useState<KnownHistory>(() => ({ keys: [key], index: 0, browserIndex }));
  let history = recorded;

  if (recorded.keys[recorded.index] !== key) {
    if (navigationType === "PUSH") {
      // Batched pushes can hide an intermediate location from React. The
      // router's index proves adjacency; it never supplies unseen entries.
      const adjacent = !trackBrowserIndex || (browserIndex !== undefined && recorded.browserIndex !== undefined && browserIndex === recorded.browserIndex + 1);
      const keys = adjacent ? [...recorded.keys.slice(0, recorded.index + 1), key].slice(-retainedEntries) : [key];
      history = { keys, index: keys.length - 1, browserIndex };
    } else if (navigationType === "REPLACE") {
      const samePosition = !trackBrowserIndex || (browserIndex !== undefined && browserIndex === recorded.browserIndex);
      history = samePosition
        ? { keys: recorded.keys.map((entry, index) => index === recorded.index ? key : entry), index: recorded.index, browserIndex }
        : { keys: [key], index: 0, browserIndex };
    } else {
      const index = recorded.keys.indexOf(key);
      // A browser/OS traversal outside our known sequence has no reliable
      // relative position. Start a new sequence rather than inventing one.
      const knownPosition = !trackBrowserIndex || (browserIndex !== undefined && recorded.browserIndex !== undefined && browserIndex === recorded.browserIndex - recorded.index + index);
      history = index === -1 || !knownPosition ? { keys: [key], index: 0, browserIndex } : { ...recorded, index, browserIndex };
    }
    // Update before rendering consumers so a pushed branch never briefly
    // exposes the forward entry that the router has already discarded.
    setRecorded(history);
  }

  const canGoBack = history.index > 0;
  const canGoForward = history.index < history.keys.length - 1;
  const onBack = useCallback(() => { if (canGoBack) void navigate(-1); }, [canGoBack, navigate]);
  const onForward = useCallback(() => { if (canGoForward) void navigate(1); }, [canGoForward, navigate]);
  const value = useMemo(() => ({ canGoBack, canGoForward, onBack, onForward }), [canGoBack, canGoForward, onBack, onForward]);

  return <RouterHistoryContext value={value}>{children}</RouterHistoryContext>;
}

export function useRouterHistory(): RouterHistoryNavigation {
  const history = useContext(RouterHistoryContext);
  if (!history) throw new Error("Router history controls require RouterHistoryProvider");
  return history;
}
