import { useEffect, useMemo } from "react";
import { useLocation } from "react-router-dom";

const routeLabels: Record<string, string> = {
  "/app": "Messages",
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

export function routeLabel(pathname: string, search: string): string {
  const normalizedPath = pathname.length > 1 ? pathname.replace(/\/+$/, "") : pathname;
  const base = routeLabels[normalizedPath] ?? "K-Comms";
  if (normalizedPath !== "/admin") return base;
  const section = new URLSearchParams(search).get("section");
  const sectionLabel = section ? adminSectionLabels[section] : null;
  return sectionLabel ? `${sectionLabel} · ${base}` : base;
}

export function RouteOrientation() {
  const location = useLocation();
  const label = useMemo(
    () => routeLabel(location.pathname, location.search),
    [location.pathname, location.search]
  );

  useEffect(() => {
    document.title = label === "K-Comms" ? label : `${label} | K-Comms`;
  }, [label]);

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      const main = document.querySelector<HTMLElement>("main#main-content, main");
      const activeElement = document.activeElement;
      if (main && activeElement instanceof HTMLElement && main.contains(activeElement) && activeElement.matches("input, select, textarea, button, a[href], [autofocus]")) return;
      const destination = document.querySelector<HTMLElement>("main#main-content h1, main h1")
        ?? main;
      if (!destination) return;
      const hadTabIndex = destination.hasAttribute("tabindex");
      if (!hadTabIndex) destination.setAttribute("tabindex", "-1");
      destination.focus({ preventScroll: true });
      if (!hadTabIndex) {
        destination.addEventListener("blur", () => destination.removeAttribute("tabindex"), { once: true });
      }
    });
    return () => window.cancelAnimationFrame(frame);
  }, [location.pathname]);

  return <span className="sr-only" aria-live="polite" aria-atomic="true">{label} view</span>;
}
