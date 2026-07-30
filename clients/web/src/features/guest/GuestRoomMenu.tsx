import type { ReactNode } from "react";
import { Link } from "react-router";
import { AppIcon } from "../../components/AppIcon";
import { AppMenuCloseButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";

export function GuestRoomMenu({
  canKeepRoom,
  identityLabel,
  inviteContent,
  leaving,
  onClose,
  onKeepRoom,
  onLeave,
  warnsOfGuestHostLoss
}: {
  canKeepRoom: boolean;
  identityLabel: "Guest" | "Host" | "Member";
  inviteContent?: ReactNode;
  leaving: boolean;
  onClose: () => void;
  onKeepRoom: () => void;
  onLeave: () => void;
  warnsOfGuestHostLoss: boolean;
}) {
  const dialogRef = useModalDialog(onClose);

  return (
    <div
      className="guest-room-menu-backdrop"
      onPointerDown={(event) => {
        if (event.currentTarget === event.target) onClose();
      }}
    >
      <aside
        ref={dialogRef}
        className="guest-room-menu"
        id="guest-room-menu"
        role="dialog"
        aria-modal="true"
        aria-labelledby="guest-room-menu-title"
      >
        <header>
          <h2 id="guest-room-menu-title">Room menu</h2>
          <AppMenuCloseButton
            data-initial-focus
            accessibleLabel="Close"
            onClick={onClose}
          />
        </header>
        {inviteContent}
        <div className="guest-room-menu-actions">
          {canKeepRoom && (
            <button
              className="guest-room-menu-action"
              type="button"
              onClick={onKeepRoom}
            >
              <AppIcon name="bookmark" />
              <div>
                <strong>
                  {identityLabel === "Host"
                    ? "Save this room"
                    : "Keep this conversation"}
                </strong>
                <span>Continue from another device with an account.</span>
              </div>
            </button>
          )}
          {identityLabel === "Host" && (
            <Link
              className="guest-room-menu-action"
              to="/sign-in"
              onClick={onClose}
            >
              <AppIcon name="logIn" />
              <div>
                <strong>Sign in to a workspace</strong>
                <span>Use an existing K-Comms account.</span>
              </div>
            </Link>
          )}
          <button
            className="guest-room-menu-action danger"
            type="button"
            disabled={leaving}
            onClick={onLeave}
          >
            <AppIcon name="logOut" />
            <div>
              <strong>{leaving ? "Leaving room…" : "Leave room"}</strong>
              <span>
                {warnsOfGuestHostLoss
                  ? "Leaving clears this guest host session. Copy the invite to rejoin, or save the room first to keep management access."
                  : "This ends only your session on this device."}
              </span>
            </div>
          </button>
        </div>
      </aside>
    </div>
  );
}
