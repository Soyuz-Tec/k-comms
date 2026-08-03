import {
  forwardRef,
  useImperativeHandle,
  useRef,
  useState,
  type CSSProperties,
  type HTMLAttributes,
  type PointerEvent as ReactPointerEvent
} from "react";
import { AppIcon } from "./AppIcon";
import "./DraggableSurface.css";

interface Point {
  x: number;
  y: number;
}

interface DragOrigin {
  pointerId: number;
  pointer: Point;
  offset: Point;
  surface: DOMRect;
  boundary: DOMRect;
}

export interface DraggableSurfaceProps
  extends HTMLAttributes<HTMLDivElement> {
  dragLabel: string;
  initialOffset?: Point;
}

const EDGE_GAP = 8;

function viewportBoundary(): DOMRect {
  return new DOMRect(0, 0, window.innerWidth, window.innerHeight);
}

function clampOffset(
  next: Point,
  originOffset: Point,
  surface: DOMRect,
  boundary: DOMRect
): Point {
  const minimumX = originOffset.x + boundary.left + EDGE_GAP - surface.left;
  const maximumX = originOffset.x + boundary.right - EDGE_GAP - surface.right;
  const minimumY = originOffset.y + boundary.top + EDGE_GAP - surface.top;
  const maximumY = originOffset.y + boundary.bottom - EDGE_GAP - surface.bottom;

  return {
    x: Math.min(Math.max(next.x, minimumX), Math.max(minimumX, maximumX)),
    y: Math.min(Math.max(next.y, minimumY), Math.max(minimumY, maximumY))
  };
}

export const DraggableSurface = forwardRef<
  HTMLElement,
  DraggableSurfaceProps
>(function DraggableSurface(
  {
    children,
    className = "",
    dragLabel,
    initialOffset = { x: 0, y: 0 },
    style,
    ...surfaceProps
  },
  forwardedRef
) {
  const surfaceRef = useRef<HTMLDivElement | null>(null);
  const dragOriginRef = useRef<DragOrigin | null>(null);
  const [offset, setOffset] = useState(initialOffset);
  const [dragging, setDragging] = useState(false);

  useImperativeHandle(forwardedRef, () => surfaceRef.current as HTMLDivElement);

  function boundaryForSurface(surface: HTMLDivElement): DOMRect {
    return surface.offsetParent?.getBoundingClientRect() ?? viewportBoundary();
  }

  function startDrag(event: ReactPointerEvent<HTMLButtonElement>) {
    if (event.button !== 0) return;
    const surface = surfaceRef.current;
    if (!surface) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    dragOriginRef.current = {
      pointerId: event.pointerId,
      pointer: { x: event.clientX, y: event.clientY },
      offset,
      surface: surface.getBoundingClientRect(),
      boundary: boundaryForSurface(surface)
    };
    setDragging(true);
  }

  function moveDrag(event: ReactPointerEvent<HTMLButtonElement>) {
    const origin = dragOriginRef.current;
    if (!origin || origin.pointerId !== event.pointerId) return;
    setOffset(clampOffset(
      {
        x: origin.offset.x + event.clientX - origin.pointer.x,
        y: origin.offset.y + event.clientY - origin.pointer.y
      },
      origin.offset,
      origin.surface,
      origin.boundary
    ));
  }

  function finishDrag(event: ReactPointerEvent<HTMLButtonElement>) {
    const origin = dragOriginRef.current;
    if (!origin || origin.pointerId !== event.pointerId) return;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
    dragOriginRef.current = null;
    setDragging(false);
  }

  function moveWithKeyboard(event: React.KeyboardEvent<HTMLButtonElement>) {
    const direction = {
      ArrowDown: { x: 0, y: 1 },
      ArrowLeft: { x: -1, y: 0 },
      ArrowRight: { x: 1, y: 0 },
      ArrowUp: { x: 0, y: -1 }
    }[event.key];
    if (!direction) return;
    const surface = surfaceRef.current;
    if (!surface) return;
    event.preventDefault();
    const distance = event.shiftKey ? 32 : 8;
    const surfaceBox = surface.getBoundingClientRect();
    setOffset((current) => clampOffset(
      {
        x: current.x + direction.x * distance,
        y: current.y + direction.y * distance
      },
      current,
      surfaceBox,
      boundaryForSurface(surface)
    ));
  }

  const surfaceStyle: CSSProperties = {
    ...style,
    transform: `translate3d(${offset.x}px, ${offset.y}px, 0)`
  };

  return (
    <div
      {...surfaceProps}
      ref={surfaceRef}
      className={`draggable-surface ${className}`.trim()}
      data-dragging={dragging ? "true" : "false"}
      style={surfaceStyle}
    >
      <button
        className="draggable-surface-handle"
        type="button"
        aria-label={`Move ${dragLabel}`}
        title={`Drag to move ${dragLabel}. Use arrow keys for precise movement.`}
        onKeyDown={moveWithKeyboard}
        onPointerCancel={finishDrag}
        onPointerDown={startDrag}
        onPointerMove={moveDrag}
        onPointerUp={finishDrag}
      >
        <AppIcon name="grip" />
      </button>
      {children}
    </div>
  );
});
