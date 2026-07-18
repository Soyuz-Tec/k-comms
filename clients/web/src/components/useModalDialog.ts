import { useEffect, useRef } from "react";

const focusableSelector = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled]):not([type='hidden'])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[contenteditable='true']",
  "[tabindex]:not([tabindex='-1'])"
].join(",");

interface BackgroundState {
  count: number;
  inert: boolean;
  ariaHidden: string | null;
}

const isolatedElements = new Map<HTMLElement, BackgroundState>();
const activeDialogs: HTMLElement[] = [];
let bodyScrollLocks = 0;
let bodyOverflow = "";
let bodyOverscrollBehavior = "";
let bodyPaddingRight = "";

function lockBodyScroll() {
  if (bodyScrollLocks > 0) {
    bodyScrollLocks += 1;
    return;
  }

  bodyScrollLocks = 1;
  bodyOverflow = document.body.style.overflow;
  bodyOverscrollBehavior = document.body.style.overscrollBehavior;
  bodyPaddingRight = document.body.style.paddingRight;
  const scrollbarWidth = Math.max(0, window.innerWidth - document.documentElement.clientWidth);
  document.body.style.overflow = "hidden";
  document.body.style.overscrollBehavior = "none";
  if (scrollbarWidth > 0) document.body.style.paddingRight = `${scrollbarWidth}px`;
}

function unlockBodyScroll() {
  bodyScrollLocks = Math.max(0, bodyScrollLocks - 1);
  if (bodyScrollLocks > 0) return;
  document.body.style.overflow = bodyOverflow;
  document.body.style.overscrollBehavior = bodyOverscrollBehavior;
  document.body.style.paddingRight = bodyPaddingRight;
}

function isAvailable(element: HTMLElement): boolean {
  const style = window.getComputedStyle(element);
  return !element.hidden
    && element.getAttribute("aria-hidden") !== "true"
    && !element.closest("[inert]")
    && style.display !== "none"
    && style.visibility !== "hidden";
}

function focusableElements(dialog: HTMLElement): HTMLElement[] {
  return [...dialog.querySelectorAll<HTMLElement>(focusableSelector)].filter(isAvailable);
}

function isolate(element: HTMLElement) {
  const state = isolatedElements.get(element);
  if (state) {
    state.count += 1;
    return;
  }
  isolatedElements.set(element, {
    count: 1,
    inert: Boolean(element.inert),
    ariaHidden: element.getAttribute("aria-hidden")
  });
  element.inert = true;
  element.setAttribute("aria-hidden", "true");
}

function restore(element: HTMLElement) {
  const state = isolatedElements.get(element);
  if (!state) return;
  state.count -= 1;
  if (state.count > 0) return;
  element.inert = state.inert;
  if (state.ariaHidden === null) element.removeAttribute("aria-hidden");
  else element.setAttribute("aria-hidden", state.ariaHidden);
  isolatedElements.delete(element);
}

function isolateBackground(dialog: HTMLElement): HTMLElement[] {
  const isolated: HTMLElement[] = [];
  let activeBranch: HTMLElement | null = dialog;

  while (activeBranch?.parentElement) {
    const parentElement: HTMLElement = activeBranch.parentElement;
    for (const sibling of parentElement.children) {
      if (!(sibling instanceof HTMLElement) || sibling === activeBranch) continue;
      isolate(sibling);
      isolated.push(sibling);
    }
    if (parentElement === document.body) break;
    activeBranch = parentElement;
  }

  return isolated;
}

export function useModalDialog(onClose: () => void) {
  const dialogRef = useRef<HTMLElement | null>(null);
  const restoreTargetRef = useRef<HTMLElement | null>(
    document.activeElement instanceof HTMLElement ? document.activeElement : null
  );
  const closeRef = useRef(onClose);
  closeRef.current = onClose;

  useEffect(() => {
    const currentDialog = dialogRef.current;
    if (!currentDialog) return;
    const dialog: HTMLElement = currentDialog;

    activeDialogs.push(dialog);
    lockBodyScroll();
    const isolated = isolateBackground(dialog);
    const initial = dialog.querySelector<HTMLElement>("[data-initial-focus], [autofocus]")
      ?? focusableElements(dialog)[0]
      ?? dialog;
    const frame = window.requestAnimationFrame(() => initial.focus());

    function keyDown(event: KeyboardEvent) {
      if (activeDialogs.at(-1) !== dialog) return;
      if (event.key === "Escape") {
        event.preventDefault();
        closeRef.current();
        return;
      }
      if (event.key !== "Tab") return;
      const available = focusableElements(dialog);
      if (available.length === 0) {
        event.preventDefault();
        dialog.focus();
        return;
      }
      const first = available[0];
      const last = available.at(-1);
      if (!first || !last) return;
      if (event.shiftKey && (document.activeElement === first || !dialog.contains(document.activeElement))) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && (document.activeElement === last || !dialog.contains(document.activeElement))) {
        event.preventDefault();
        first.focus();
      }
    }

    function containFocus(event: FocusEvent) {
      if (activeDialogs.at(-1) !== dialog) return;
      if (event.target instanceof Node && !dialog.contains(event.target)) {
        const fallback = focusableElements(dialog)[0] ?? dialog;
        fallback.focus();
      }
    }

    document.addEventListener("keydown", keyDown, true);
    document.addEventListener("focusin", containFocus, true);
    return () => {
      window.cancelAnimationFrame(frame);
      document.removeEventListener("keydown", keyDown, true);
      document.removeEventListener("focusin", containFocus, true);
      const stackIndex = activeDialogs.lastIndexOf(dialog);
      if (stackIndex >= 0) activeDialogs.splice(stackIndex, 1);
      unlockBodyScroll();
      for (const element of isolated) restore(element);
      window.requestAnimationFrame(() => {
        const target = restoreTargetRef.current;
        if (target?.isConnected && !target.inert) target.focus();
      });
    };
  }, []);

  return dialogRef;
}
