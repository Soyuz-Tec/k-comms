import {
  forwardRef,
  type ButtonHTMLAttributes,
  type HTMLAttributes
} from "react";
import { AppIcon, type AppIconName } from "./AppIcon";

interface AppMenuTriggerProps
  extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, "aria-controls"> {
  accessibleLabel: string;
  controls: string;
  expanded: boolean;
  overlay?: boolean;
}

/**
 * The one primary-navigation trigger used by the member shell, guest rooms,
 * and active calls. The physical placement is owned by each surface, while the
 * target size, familiar icon, and dialog semantics stay invariant.
 */
export const AppMenuTrigger = forwardRef<
  HTMLButtonElement,
  AppMenuTriggerProps
>(function AppMenuTrigger(
  {
    accessibleLabel,
    className = "",
    controls,
    expanded,
    overlay = false,
    title = "Menu",
    ...buttonProps
  },
  ref
) {
  return (
    <button
      {...buttonProps}
      ref={ref}
      className={`app-menu-trigger${overlay ? " app-menu-trigger-overlay" : ""} ${className}`.trim()}
      type="button"
      aria-label={accessibleLabel}
      aria-haspopup="dialog"
      aria-expanded={expanded}
      aria-controls={controls}
      title={title}
    >
      <AppIcon name="menu" />
      <span className="visually-hidden">Menu</span>
    </button>
  );
});

interface AppMenuCloseButtonProps
  extends ButtonHTMLAttributes<HTMLButtonElement> {
  accessibleLabel: string;
}

export function AppMenuCloseButton({
  accessibleLabel,
  className = "",
  ...buttonProps
}: AppMenuCloseButtonProps) {
  return (
    <AppSurfaceControlButton
      {...buttonProps}
      accessibleLabel={accessibleLabel}
      className={`app-menu-close ${className}`.trim()}
      kind="close"
      label="Close"
      showLabel
    />
  );
}

type AppSurfaceControlKind = "close" | "expand" | "minimize" | "restore";

const surfaceControlIcons: Record<AppSurfaceControlKind, AppIconName> = {
  close: "x",
  expand: "maximize",
  minimize: "minimize",
  restore: "maximize"
};

interface AppSurfaceControlButtonProps
  extends ButtonHTMLAttributes<HTMLButtonElement> {
  accessibleLabel: string;
  kind: AppSurfaceControlKind;
  label?: string;
  showLabel?: boolean;
}

/**
 * Familiar window-like surface controls. Close is universal for dismissible
 * overlays; minimize/expand/restore are rendered only when a surface actually
 * supports that state.
 */
export const AppSurfaceControlButton = forwardRef<
  HTMLButtonElement,
  AppSurfaceControlButtonProps
>(function AppSurfaceControlButton(
  {
    accessibleLabel,
    className = "",
    kind,
    label = accessibleLabel,
    showLabel = false,
    title = accessibleLabel,
    ...buttonProps
  },
  ref
) {
  return (
    <button
      {...buttonProps}
      ref={ref}
      className={`app-surface-control app-surface-control-${kind} ${className}`.trim()}
      type="button"
      aria-label={accessibleLabel}
      title={title}
    >
      <AppIcon name={surfaceControlIcons[kind]} />
      <span className={showLabel ? undefined : "visually-hidden"}>{label}</span>
    </button>
  );
});

export function AppSurfaceControlCluster({
  "aria-label": accessibleLabel = "Window controls",
  children,
  className = "",
  ...props
}: HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      {...props}
      className={`app-surface-control-cluster ${className}`.trim()}
      role="group"
      aria-label={accessibleLabel}
    >
      {children}
    </div>
  );
}
