import { createContext, useContext } from "react";
import type { ReactNode } from "react";
import { createPortal } from "react-dom";

interface NavigationState {
  target: HTMLElement | null;
  /** A pinned sidebar is a persistent alternative to in-page shortcuts. */
  hasSidebarNavigation: boolean;
}

const NavigationContext = createContext<NavigationState>({ target: null, hasSidebarNavigation: false });

export function ContextualNavigationProvider({ target, hasSidebarNavigation, children }: NavigationState & { children: ReactNode }) {
  return <NavigationContext.Provider value={{ target, hasSidebarNavigation }}>{children}</NavigationContext.Provider>;
}

export function useContextualNavigation() {
  return useContext(NavigationContext);
}

/** Move only navigation; the page and its providers keep their owning tree. */
export function ContextualNavigation({ children }: { children: ReactNode }) {
  const { target } = useContextualNavigation();
  return target ? createPortal(children, target) : children;
}
