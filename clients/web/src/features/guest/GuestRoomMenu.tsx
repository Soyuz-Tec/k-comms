import type { ReactNode } from "react";
import { Link } from "react-router";
import { AppIcon } from "../../components/AppIcon";
import { AppMenuCloseButton } from "../../components/AppMenuControls";
import { DraggableSurface } from "../../components/DraggableSurface";
import { useModalDialog } from "../../components/useModalDialog";

export function GuestRoomMenu({
  canKeepRoom,
  callContent,
  floating = false,
  identityLabel,
  inviteContent,
  leaving,
  onClearBoard,
  onClose,
  onKeepRoom,
  onLeave,
  open = true,
  participantContent,
  roomMeta,
  roomTitle,
  warnsOfGuestHostLoss
}: {
  canKeepRoom: boolean;
  callContent?: ReactNode;
  floating?: boolean;
  identityLabel: "Guest" | "Host" | "Member";
  inviteContent?: ReactNode;
  leaving: boolean;
  onClearBoard?: () => void;
  onClose: () => void;
  onKeepRoom: () => void;
  onLeave: () => void;
  open?: boolean;
  participantContent?: ReactNode;
  roomMeta?: ReactNode;
  roomTitle?: string;
  warnsOfGuestHostLoss: boolean;
}) {
  const dialogRef = useModalDialog(onClose, open);

  const contents = (
    <>
      <header>
        <div>
          <span className="guest-room-menu-kicker">Room controls</span>
          <div className="guest-room-menu-title-row">
            <h2 id="guest-room-menu-title">{roomTitle || "Room menu"}</h2>
            <span className="guest-badge compact">{identityLabel}</span>
          </div>
          {roomMeta && <p>{roomMeta}</p>}
        </div>
        <AppMenuCloseButton
          data-initial-focus
          accessibleLabel="Close"
          onClick={onClose}
        />
      </header>

      <div className="guest-room-menu-sections">
        {onClearBoard && (
          <section className="guest-room-menu-section" aria-labelledby="guest-room-menu-workspace">
            <h3 id="guest-room-menu-workspace">Canvas</h3>
            <div className="guest-room-menu-actions">
              <button
                className="guest-room-menu-action danger"
                type="button"
                aria-label="Clear canvas"
                onClick={() => {
                  onClearBoard();
                  onClose();
                }}
              >
                <AppIcon name="trash" />
                <div>
                  <strong>Clear canvas</strong>
                  <span>Confirm before clearing the board for everyone.</span>
                </div>
              </button>
            </div>
          </section>
        )}

        {participantContent && (
          <section className="guest-room-menu-section" aria-label="People in this room">
            {participantContent}
          </section>
        )}

        {callContent && (
          <section className="guest-room-menu-section guest-room-menu-call-section" aria-labelledby="guest-room-menu-calls">
            <h3 id="guest-room-menu-calls">Calls</h3>
            {callContent}
          </section>
        )}

        {inviteContent && (
          <section className="guest-room-menu-section guest-room-menu-invite-section" aria-label="Invite and share">
            {inviteContent}
          </section>
        )}

        <section className="guest-room-menu-section" aria-labelledby="guest-room-menu-account">
          <h3 id="guest-room-menu-account">Account and room</h3>
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
        </section>
      </div>
    </>
  );

  const dialogProps = {
    id: "guest-room-menu",
    role: "dialog",
    "aria-modal": true,
    "aria-labelledby": "guest-room-menu-title"
  } as const;

  return (
    <div
      className="guest-room-menu-backdrop"
      hidden={!open}
      onPointerDown={(event) => {
        if (event.currentTarget === event.target) onClose();
      }}
    >
      {floating ? (
        <DraggableSurface
          {...dialogProps}
          ref={dialogRef}
          className="guest-room-menu-positioner"
          dragLabel="room controls"
        >
          <aside className="guest-room-menu">{contents}</aside>
        </DraggableSurface>
      ) : (
        <aside
          {...dialogProps}
          ref={dialogRef}
          className="guest-room-menu"
        >
          {contents}
        </aside>
      )}
    </div>
  );
}
