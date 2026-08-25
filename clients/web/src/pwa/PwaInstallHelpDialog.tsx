import { createPortal } from "react-dom";
import { AppSurfaceControlButton } from "../components/AppMenuControls";
import { useModalDialog } from "../components/useModalDialog";
import type { PwaInstallMode } from "./PwaProvider";

export type ManualInstallMode = Extract<
  PwaInstallMode,
  "manual-ios" | "manual-browser"
>;

/**
 * Lives here rather than in the shell because the shell no longer offers
 * installation: phones reach it from the You screen, which already carries the
 * install card, and the desktop rail never had a reason to own the dialog.
 */
export function PwaInstallHelpDialog({
  mode,
  onClose
}: {
  mode: ManualInstallMode;
  onClose: () => void;
}) {
  const dialogRef = useModalDialog(onClose);

  return createPortal(
    <div
      className="modal-backdrop pwa-install-backdrop"
      onPointerDown={(event) => {
        if (event.currentTarget === event.target) onClose();
      }}
    >
      <section
        ref={dialogRef}
        className="modal-dialog pwa-install-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="pwa-install-help-title"
        aria-describedby="pwa-install-help-copy"
      >
        <div className="pwa-install-dialog-heading">
          <div>
            <span className="eyebrow">No App Store needed</span>
            <h2 id="pwa-install-help-title">Install K-Comms</h2>
          </div>
          <AppSurfaceControlButton
            data-initial-focus
            accessibleLabel="Close install instructions"
            kind="close"
            onClick={onClose}
          />
        </div>
        {mode === "manual-ios" ? (
          <p id="pwa-install-help-copy">
            On iPhone or iPad, tap <strong>Share → Add to Home Screen</strong>.
            Keep <strong>Open as Web App</strong> enabled, then tap Add.
          </p>
        ) : (
          <p id="pwa-install-help-copy">
            Open your browser menu, then choose <strong>Install app</strong> or{" "}
            <strong>Add to Home screen</strong>.
          </p>
        )}
        <button className="button primary pwa-install-done" type="button" onClick={onClose}>
          Done
        </button>
      </section>
    </div>,
    document.body
  );
}
