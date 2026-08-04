import {
  useEffect,
  useRef,
  type KeyboardEvent,
  type RefObject
} from "react";
import { AppIcon } from "../../components/AppIcon";

export function GuestMessageMenu({
  onClose,
  onCollapse,
  onFocusComposer,
  onJumpToLatest,
  triggerRef
}: {
  onClose: () => void;
  onCollapse: () => void;
  onFocusComposer: () => void;
  onJumpToLatest: () => void;
  triggerRef: RefObject<HTMLButtonElement | null>;
}) {
  const menuRef = useRef<HTMLDivElement | null>(null);
  const firstActionRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    firstActionRef.current?.focus();

    function closeFromOutside(event: PointerEvent) {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (
        !menuRef.current?.contains(target) &&
        !triggerRef.current?.contains(target)
      ) {
        onClose();
      }
    }

    document.addEventListener("pointerdown", closeFromOutside);
    return () => document.removeEventListener("pointerdown", closeFromOutside);
  }, [onClose, triggerRef]);

  function moveMenuFocus(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Escape") {
      event.preventDefault();
      onClose();
      triggerRef.current?.focus();
      return;
    }

    const actions = Array.from(
      menuRef.current?.querySelectorAll<HTMLButtonElement>(
        '[role="menuitem"]:not(:disabled)'
      ) ?? []
    );
    if (actions.length === 0) return;
    const currentIndex = actions.indexOf(document.activeElement as HTMLButtonElement);
    const nextIndex = event.key === "ArrowDown"
      ? (currentIndex + 1) % actions.length
      : event.key === "ArrowUp"
        ? (currentIndex - 1 + actions.length) % actions.length
        : event.key === "Home"
          ? 0
          : event.key === "End"
            ? actions.length - 1
            : null;
    if (nextIndex === null) return;
    event.preventDefault();
    actions[nextIndex]?.focus();
  }

  function run(action: () => void) {
    onClose();
    action();
  }

  return (
    <div
      ref={menuRef}
      className="guest-message-menu"
      id="guest-message-menu"
      role="menu"
      aria-label="Message controls"
      onKeyDown={moveMenuFocus}
    >
      <span className="guest-message-menu-label">Message controls</span>
      <button
        ref={firstActionRef}
        type="button"
        role="menuitem"
        onClick={() => run(onFocusComposer)}
      >
        <AppIcon name="pencil" />
        <span>
          <strong>Write a message</strong>
          <small>Move focus to the message box.</small>
        </span>
      </button>
      <button
        type="button"
        role="menuitem"
        onClick={() => run(onJumpToLatest)}
      >
        <AppIcon name="arrowDown" />
        <span>
          <strong>Jump to latest</strong>
          <small>Show the newest message in this room.</small>
        </span>
      </button>
      <button
        type="button"
        role="menuitem"
        onClick={() => run(onCollapse)}
      >
        <AppIcon name="minimize" />
        <span>
          <strong>Collapse messages</strong>
          <small>Keep the message header available on the canvas.</small>
        </span>
      </button>
    </div>
  );
}
