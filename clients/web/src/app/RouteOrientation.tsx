import { useEffect, useMemo } from "react";
import { useLocation } from "react-router";

const routeLabels: Record<string, string> = {
  "/app": "Inbox",
  "/app/calls": "Calls",
  "/app/directory": "Directory",
  "/app/files": "Files",
  "/app/you": "You",
  "/app/settings": "Profile and settings",
  "/admin": "Workspace administration",
  "/ops": "Service operations",
  "/forgot-password": "Password recovery",
  "/reset-password": "Reset password"
};

const adminSectionLabels: Record<string, string> = {
  workspace: "Workspace",
  people: "People",
  safety: "Safety",
  integrations: "Integrations",
  audit: "Audit",
  governance: "Governance"
};

function isRendered(element: HTMLElement): boolean {
  if (element.closest("[hidden], [aria-hidden='true']")) return false;
  const style = window.getComputedStyle(element);
  if (style.display === "none" || style.visibility === "hidden") return false;
  return (
    element.getClientRects().length > 0 ||
    /\bjsdom\b/i.test(window.navigator.userAgent)
  );
}

function routeDestination(): HTMLElement | null {
  const main = document.querySelector<HTMLElement>("main#main-content, main");
  if (!main) return null;
  const explicit = [
    ...main.querySelectorAll<HTMLElement>("[data-route-focus]")
  ].find(isRendered);
  if (explicit) return explicit;
  return [...main.querySelectorAll<HTMLElement>("h1")].find(isRendered) ?? main;
}

function focusRouteDestination(destination: HTMLElement, scroll = false) {
  if (scroll) destination.scrollIntoView({ block: "start" });
  const hadTabIndex = destination.hasAttribute("tabindex");
  if (!hadTabIndex) destination.setAttribute("tabindex", "-1");
  destination.focus({ preventScroll: true });
  if (!hadTabIndex) {
    destination.addEventListener("blur", () => destination.removeAttribute("tabindex"), { once: true });
  }
}

function fragmentId(hash: string): string | null {
  if (!hash.startsWith("#")) return null;
  try {
    const value = decodeURIComponent(hash.slice(1));
    return /^[A-Za-z][A-Za-z0-9_.:-]*$/.test(value) ? value : null;
  } catch {
    return null;
  }
}

function fragmentDestination(id: string): HTMLElement | null {
  const target = document.getElementById(id);
  if (!target || !isRendered(target)) return null;
  const focusTarget = [
    ...target.querySelectorAll<HTMLElement>("[data-route-focus], h1, h2, h3")
  ].find(isRendered);
  return focusTarget ?? target;
}

export function routeLabel(
  pathname: string,
  search: string,
  authenticated = true
): string {
  const normalizedPath = pathname.length > 1 ? pathname.replace(/\/+$/, "") : pathname;
  if (
    !authenticated &&
    normalizedPath !== "/forgot-password" &&
    normalizedPath !== "/reset-password"
  ) return "Sign in";
  const base = routeLabels[normalizedPath] ?? "K-Comms";
  if (normalizedPath !== "/admin") return base;
  const section = new URLSearchParams(search).get("section");
  const sectionLabel = section ? adminSectionLabels[section] : null;
  return sectionLabel ? `${sectionLabel} · ${base}` : base;
}

export function RouteOrientation({ authenticated = true }: { authenticated?: boolean }) {
  const location = useLocation();
  const label = useMemo(
    () => routeLabel(location.pathname, location.search, authenticated),
    [authenticated, location.pathname, location.search]
  );

  useEffect(() => {
    document.title = label === "K-Comms" ? label : `${label} | K-Comms`;
  }, [label]);

  useEffect(() => {
    let observer: MutationObserver | null = null;
    let fallbackTimer: number | null = null;
    const frame = window.requestAnimationFrame(() => {
      const main = document.querySelector<HTMLElement>("main#main-content, main");
      const activeElement = document.activeElement;
      const id = fragmentId(location.hash);

      if (id) {
        const orientToFragment = () => {
          const destination = fragmentDestination(id);
          if (!destination) return false;
          if (fallbackTimer !== null) window.clearTimeout(fallbackTimer);
          observer?.disconnect();
          focusRouteDestination(destination, true);
          return true;
        };

        if (orientToFragment()) return;
        observer = new MutationObserver(() => {
          orientToFragment();
        });
        observer.observe(document.body, { childList: true, subtree: true });
        fallbackTimer = window.setTimeout(() => {
          observer?.disconnect();
          const destination = routeDestination();
          if (destination) focusRouteDestination(destination);
        }, 1_500);
        return;
      }

      if (
        main &&
        activeElement instanceof HTMLElement &&
        main.contains(activeElement) &&
        activeElement.matches("input, select, textarea, button, a[href], [autofocus]") &&
        isRendered(activeElement)
      ) return;
      const destination = routeDestination();
      if (!destination) return;
      focusRouteDestination(destination);
    });
    return () => {
      window.cancelAnimationFrame(frame);
      observer?.disconnect();
      if (fallbackTimer !== null) window.clearTimeout(fallbackTimer);
    };
  }, [location.hash, location.pathname, location.search]);

  return <span className="sr-only" aria-live="polite" aria-atomic="true">{label} view</span>;
}
