import { useEffect, useId, useRef, useState } from "react";
import type { KeyboardEvent } from "react";
import { createPortal } from "react-dom";
import { AppIcon } from "./AppIcon";
import { useModalDialog } from "./useModalDialog";
import { getDesktopShellBridge, isNativeShellAction, validateDesktopShellState } from "../lib/desktop-shell";
import type { NativeDesktopShellState, NativeShellMenu } from "../lib/desktop-shell";
import "./DesktopShellHeader.css";

export interface DesktopShellHeaderProps {
  hideChrome?: boolean;
  sidebarExpanded?: boolean;
  sidebarId?: string;
  onToggleSidebar?: () => void;
  onNewInstantRoom: () => void;
  onOpenWorkspace: () => void;
  onOpenSearch?: () => void;
  onOpenSettings?: () => void;
  onOpenHelp?: () => void;
  workspaceName?: string;
  showWorkspaceName?: boolean;
  workspaceMenuLabel?: string;
  navigation?: {
    canGoBack: boolean;
    canGoForward: boolean;
    onBack: () => void;
    onForward: () => void;
  };
}

const menuLabels: Record<NativeShellMenu, string> = { file: "File", edit: "Edit", view: "View", help: "Help" };

function hasOpenDialog() {
  return Boolean(document.querySelector("[aria-modal='true'], dialog[open]"));
}

/** App actions in browsers; OS menus and OS-drawn controls in the native client. */
export function DesktopShellHeader(props: DesktopShellHeaderProps) {
  const id = useId();
  const headerRef = useRef<HTMLElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);
  const triggers = useRef<Array<HTMLButtonElement | null>>([]);
  const callbacks = useRef(props);
  callbacks.current = props;
  const [bridge] = useState(getDesktopShellBridge);
  const [nativeState, setNativeState] = useState<NativeDesktopShellState | null>(null);
  const [menuError, setMenuError] = useState("");
  const [focusedMenu, setFocusedMenu] = useState(0);
  const [openMenu, setOpenMenu] = useState<NativeShellMenu | null>(null);
  const [menuOffset, setMenuOffset] = useState(0);
  const [aboutOpen, setAboutOpen] = useState(false);
  const hasViewActions = Boolean(props.onToggleSidebar || props.onOpenSearch || props.onOpenSettings);
  const menus: NativeShellMenu[] = nativeState ? ["file", "edit", "view", "help"] : ["file", ...(hasViewActions ? ["view" as const] : []), "help"];

  useEffect(() => {
    if (!bridge) return;
    let active = true;
    let unsubscribe: (() => void) | undefined;
    void Promise.resolve().then(() => bridge.getState()).then((value) => {
      const state = validateDesktopShellState(value);
      if (!active) return;
      setNativeState(state);
      unsubscribe = bridge.subscribe((action) => {
        // Native application intents never cross a consent or editing dialog.
        if (!active || !isNativeShellAction(action) || hasOpenDialog()) return;
        const current = callbacks.current;
        if (action === "new-instant-room") current.onNewInstantRoom();
        else if (action === "open-workspace") current.onOpenWorkspace();
        else if (action === "open-search") current.onOpenSearch?.();
        else if (action === "toggle-sidebar") current.onToggleSidebar?.();
        else if (current.onOpenHelp) current.onOpenHelp();
        else setAboutOpen(true);
      });
    }).catch(() => { if (active) setMenuError("Desktop menus are unavailable."); });
    return () => { active = false; unsubscribe?.(); };
  }, [bridge]);

  useEffect(() => {
    if (props.hideChrome) {
      setOpenMenu(null);
      return;
    }
    if (!openMenu) return;
    menuRef.current?.querySelector<HTMLButtonElement>("button:not([disabled])")?.focus();
    function closeOutside(event: PointerEvent) {
      if (event.target instanceof Node && !headerRef.current?.contains(event.target)) setOpenMenu(null);
    }
    document.addEventListener("pointerdown", closeOutside);
    return () => document.removeEventListener("pointerdown", closeOutside);
  }, [openMenu, props.hideChrome]);

  function closeMenu(restoreFocus = false) {
    setOpenMenu(null);
    if (restoreFocus) triggers.current[focusedMenu]?.focus();
  }

  function openAt(index: number) {
    if (hasOpenDialog()) return;
    setFocusedMenu(index);
    setMenuError("");
    const menu = menus[index];
    if (!menu) return;
    if (nativeState && bridge) {
      void bridge.showMenu(menu).catch(() => setMenuError("Desktop menu could not open. Try again."));
    } else {
      const trigger = triggers.current[index];
      if (trigger && headerRef.current) setMenuOffset(trigger.getBoundingClientRect().left - headerRef.current.getBoundingClientRect().left);
      setOpenMenu(menu);
    }
  }

  function help() {
    if (props.onOpenHelp) props.onOpenHelp();
    else setAboutOpen(true);
  }

  const items: Array<{ label: string; action: () => void }> = openMenu === "file" ? [
    { label: "New instant room", action: props.onNewInstantRoom },
    { label: props.workspaceMenuLabel ?? "Go to a conversation or screen…", action: props.onOpenWorkspace }
  ] : openMenu === "view" ? [
    ...(props.onToggleSidebar ? [{ label: props.sidebarExpanded ? "Use compact navigation" : "Keep navigation open", action: props.onToggleSidebar }] : []),
    ...(props.onOpenSearch ? [{ label: "Search workspace…", action: props.onOpenSearch }] : []),
    ...(props.onOpenSettings ? [{ label: "Your settings", action: props.onOpenSettings }] : [])
  ] : [{ label: "About K-Comms", action: help }];

  function moveTrigger(index: number) {
    const next = (index + menus.length) % menus.length;
    setFocusedMenu(next);
    triggers.current[next]?.focus();
    if (openMenu) openAt(next);
  }

  function triggerKey(event: KeyboardEvent, index: number) {
    if (event.nativeEvent.isComposing || event.altKey || event.ctrlKey || event.metaKey) return;
    if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
      event.preventDefault();
      moveTrigger(index + (event.key === "ArrowRight" ? 1 : -1));
    } else if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      moveTrigger(event.key === "Home" ? 0 : menus.length - 1);
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      openAt(index);
    } else if (event.key === "Escape") {
      event.preventDefault();
      closeMenu(true);
    }
  }

  function menuKey(event: KeyboardEvent) {
    if (event.nativeEvent.isComposing || event.altKey || event.ctrlKey || event.metaKey) return;
    const options = [...(menuRef.current?.querySelectorAll<HTMLButtonElement>("button:not([disabled])") ?? [])];
    const current = options.indexOf(document.activeElement as HTMLButtonElement);
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      closeMenu(true);
    } else if (event.key === "Tab") {
      event.preventDefault();
      // Removing a focused popup before the default Tab action can drop focus
      // on the body. Continue from its trigger in the document's tab order.
      const available = [...document.querySelectorAll<HTMLElement>("a[href], button, input, select, textarea, [contenteditable], [tabindex]")]
        .filter((element) => {
          if (element.tabIndex < 0 || element.matches(":disabled") || element.closest("[inert], [hidden], [aria-hidden='true']")) return false;
          for (let ancestor: HTMLElement | null = element; ancestor; ancestor = ancestor.parentElement) {
            const style = window.getComputedStyle(ancestor);
            if (style.display === "none" || style.visibility === "hidden") return false;
          }
          return true;
        });
      const trigger = triggers.current[focusedMenu];
      const index = trigger ? available.indexOf(trigger) : -1;
      closeMenu();
      (available[index + (event.shiftKey ? -1 : 1)] ?? trigger)?.focus();
    }
    else if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
      event.preventDefault();
      moveTrigger(focusedMenu + (event.key === "ArrowRight" ? 1 : -1));
    } else if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
      event.preventDefault();
      const next = event.key === "Home" ? 0 : event.key === "End" ? options.length - 1
        : (current + (event.key === "ArrowDown" ? 1 : -1) + options.length) % options.length;
      options[next]?.focus();
    } else if (event.key.length === 1) {
      const ordered = [...options.slice(current + 1), ...options.slice(0, current + 1)];
      const match = ordered.find((option) => option.textContent?.trim().toLocaleLowerCase().startsWith(event.key.toLocaleLowerCase()));
      if (match) { event.preventDefault(); match.focus(); }
    }
  }

  return <>
    {!props.hideChrome && <header ref={headerRef} className="desktop-shell-header" data-native-platform={nativeState?.platform}
      aria-label="Desktop workspace controls" onBlurCapture={(event) => {
        if (event.relatedTarget instanceof Node && !event.currentTarget.contains(event.relatedTarget)) closeMenu();
      }}>
      <div className="desktop-shell-history" aria-label="Workspace history">
        <button type="button" className="desktop-shell-icon" aria-label="Go back" title="Go back"
          disabled={!props.navigation?.canGoBack} onClick={props.navigation?.onBack}><AppIcon name="arrowLeft" /></button>
        <button type="button" className="desktop-shell-icon" aria-label="Go forward" title="Go forward"
          disabled={!props.navigation?.canGoForward} onClick={props.navigation?.onForward}><AppIcon name="arrowLeft" className="desktop-shell-forward-icon" /></button>
        {props.onToggleSidebar && <button type="button" className="desktop-shell-icon" aria-label="Toggle workspace navigation" title="Toggle navigation"
          aria-expanded={props.sidebarExpanded} aria-controls={props.sidebarId ?? "workspace-navigation"} onClick={props.onToggleSidebar}>
          <AppIcon name={props.sidebarExpanded ? "panelLeftClose" : "panelLeftOpen"} />
        </button>}
      </div>
      <div className="desktop-shell-menubar" role="menubar" aria-label="Application menu">
        {menus.map((menu, index) => <button key={menu} ref={(element) => { triggers.current[index] = element; }}
          type="button" role="menuitem" tabIndex={focusedMenu === index ? 0 : -1}
          aria-haspopup="menu" aria-expanded={nativeState ? undefined : openMenu === menu}
          aria-controls={!nativeState && openMenu === menu ? `${id}-menu` : undefined}
          id={`${id}-${menu}`} onFocus={() => setFocusedMenu(index)}
          onClick={() => { if (!nativeState && openMenu === menu) closeMenu(true); else openAt(index); }}
          onKeyDown={(event) => triggerKey(event, index)}>{menuLabels[menu]}</button>)}
      </div>
      {props.showWorkspaceName !== false && <span className="desktop-shell-workspace" title={props.workspaceName}>{props.workspaceName ?? "K-Comms"}</span>}
      {menuError && <span className="desktop-shell-menu-status" role="status">{menuError}</span>}
      {openMenu && !nativeState && <div ref={menuRef} className="desktop-shell-menu" id={`${id}-menu`}
        style={{ left: menuOffset }} role="menu" aria-labelledby={`${id}-${openMenu}`} onKeyDown={menuKey}>
        {items.map((item) => <button key={item.label} type="button" role="menuitem" tabIndex={-1}
          onClick={() => { closeMenu(true); if (!hasOpenDialog()) item.action(); }}>{item.label}</button>)}
      </div>}
    </header>}
    {aboutOpen && <DesktopShellAbout native={Boolean(nativeState)} onClose={() => setAboutOpen(false)} />}
  </>;
}

function DesktopShellAbout({ native, onClose }: { native: boolean; onClose: () => void }) {
  const id = useId();
  const dialogRef = useModalDialog(onClose);
  return createPortal(<div className="modal-backdrop desktop-shell-about-backdrop" onPointerDown={(event) => {
    if (event.target === event.currentTarget) onClose();
  }}>
    <section ref={dialogRef} className="desktop-shell-about" role="dialog" aria-modal="true" aria-labelledby={`${id}-title`}
      aria-describedby={`${id}-description`} tabIndex={-1}>
      <header><h2 id={`${id}-title`}>K-Comms</h2><button type="button" className="icon-button" aria-label="Close About K-Comms" onClick={onClose}><AppIcon name="x" /></button></header>
      <p id={`${id}-description`}>Your workspace for conversations, calls and collaboration.</p>
      {native && <p>Unsigned desktop evaluation. Automatic updates are off.</p>}
      <button type="button" className="button ghost" data-initial-focus onClick={onClose}>Close</button>
    </section>
  </div>, document.body);
}
