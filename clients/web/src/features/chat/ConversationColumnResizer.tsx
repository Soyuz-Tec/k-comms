import { useRef, type PointerEvent as ReactPointerEvent } from "react";

export const CONVERSATION_SIDEBAR_DEFAULT_WIDTH = 340;
export const CONVERSATION_SIDEBAR_MIN_WIDTH = 280;
export const CONVERSATION_SIDEBAR_MAX_WIDTH = 520;
export const CONVERSATION_SIDEBAR_WIDTH_STORAGE_KEY =
  "k-comms.conversation-sidebar-width.v1";

interface DragOrigin {
  pointerId: number;
  clientX: number;
  width: number;
}

export function clampConversationSidebarWidth(width: number): number {
  return Math.min(
    CONVERSATION_SIDEBAR_MAX_WIDTH,
    Math.max(CONVERSATION_SIDEBAR_MIN_WIDTH, Math.round(width))
  );
}

export function readConversationSidebarWidth(): number {
  try {
    const stored = Number.parseInt(
      window.localStorage.getItem(CONVERSATION_SIDEBAR_WIDTH_STORAGE_KEY) || "",
      10
    );
    return Number.isFinite(stored)
      ? clampConversationSidebarWidth(stored)
      : CONVERSATION_SIDEBAR_DEFAULT_WIDTH;
  } catch {
    return CONVERSATION_SIDEBAR_DEFAULT_WIDTH;
  }
}

export function persistConversationSidebarWidth(width: number): void {
  try {
    window.localStorage.setItem(
      CONVERSATION_SIDEBAR_WIDTH_STORAGE_KEY,
      String(clampConversationSidebarWidth(width))
    );
  } catch {
    // Resizing remains available when durable browser storage is unavailable.
  }
}

export function ConversationColumnResizer({
  width,
  onWidthChange
}: {
  width: number;
  onWidthChange: (width: number) => void;
}) {
  const dragOriginRef = useRef<DragOrigin | null>(null);

  function maximumWidth(handle: HTMLElement): number {
    const availableWidth = handle.parentElement?.getBoundingClientRect().width;
    if (!availableWidth) return CONVERSATION_SIDEBAR_MAX_WIDTH;
    return Math.max(
      CONVERSATION_SIDEBAR_MIN_WIDTH,
      Math.min(CONVERSATION_SIDEBAR_MAX_WIDTH, availableWidth - 360)
    );
  }

  function constrain(nextWidth: number, handle: HTMLElement): number {
    return Math.min(
      maximumWidth(handle),
      Math.max(CONVERSATION_SIDEBAR_MIN_WIDTH, Math.round(nextWidth))
    );
  }

  function startResize(event: ReactPointerEvent<HTMLDivElement>) {
    if (event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    dragOriginRef.current = {
      pointerId: event.pointerId,
      clientX: event.clientX,
      width
    };
    event.currentTarget.dataset.resizing = "true";
  }

  function resize(event: ReactPointerEvent<HTMLDivElement>) {
    const origin = dragOriginRef.current;
    if (!origin || origin.pointerId !== event.pointerId) return;
    onWidthChange(constrain(
      origin.width + event.clientX - origin.clientX,
      event.currentTarget
    ));
  }

  function finishResize(event: ReactPointerEvent<HTMLDivElement>) {
    const origin = dragOriginRef.current;
    if (!origin || origin.pointerId !== event.pointerId) return;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
    dragOriginRef.current = null;
    delete event.currentTarget.dataset.resizing;
  }

  function resizeWithKeyboard(event: React.KeyboardEvent<HTMLDivElement>) {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    if (event.key === "Home") {
      onWidthChange(CONVERSATION_SIDEBAR_MIN_WIDTH);
      return;
    }
    if (event.key === "End") {
      onWidthChange(maximumWidth(event.currentTarget));
      return;
    }
    const distance = event.shiftKey ? 40 : 16;
    const direction = event.key === "ArrowLeft" ? -1 : 1;
    onWidthChange(constrain(width + direction * distance, event.currentTarget));
  }

  return (
    <div
      className="conversation-column-resizer"
      role="separator"
      aria-label="Resize conversation list"
      aria-orientation="vertical"
      aria-valuemin={CONVERSATION_SIDEBAR_MIN_WIDTH}
      aria-valuemax={CONVERSATION_SIDEBAR_MAX_WIDTH}
      aria-valuenow={Math.round(width)}
      tabIndex={0}
      title="Drag to resize the conversation list. Use the left and right arrow keys for precise control."
      onDoubleClick={() => onWidthChange(CONVERSATION_SIDEBAR_DEFAULT_WIDTH)}
      onKeyDown={resizeWithKeyboard}
      onPointerCancel={finishResize}
      onPointerDown={startResize}
      onPointerMove={resize}
      onPointerUp={finishResize}
    />
  );
}
