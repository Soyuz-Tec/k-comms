import { useEffect, useRef } from "react";

const focusable = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])"
].join(",");

export function useModalDialog(onClose: () => void) {
  const dialogRef = useRef<HTMLElement | null>(null);
  const restoreTargetRef = useRef<HTMLElement | null>(
    document.activeElement instanceof HTMLElement ? document.activeElement : null
  );
  const closeRef = useRef(onClose);
  closeRef.current = onClose;

  useEffect(() => {
    const dialog = dialogRef.current;
    const initial = dialog?.querySelector<HTMLElement>("[data-initial-focus], [autofocus]") || dialog?.querySelector<HTMLElement>(focusable);
    window.requestAnimationFrame(() => initial?.focus());

    function keyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        event.preventDefault();
        closeRef.current();
        return;
      }
      if (event.key !== "Tab" || !dialog) return;
      const available = [...dialog.querySelectorAll<HTMLElement>(focusable)].filter((element) => !element.hidden);
      if (available.length === 0) return event.preventDefault();
      const first = available[0];
      const last = available.at(-1);
      if (!first) return;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }

    document.addEventListener("keydown", keyDown, true);
    return () => {
      document.removeEventListener("keydown", keyDown, true);
      window.requestAnimationFrame(() => restoreTargetRef.current?.focus());
    };
  }, []);

  return dialogRef;
}
