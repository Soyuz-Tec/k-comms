import { useState, type RefObject } from "react";
import { createPortal } from "react-dom";
import { Link } from "react-router";
import { AppIcon } from "../../components/AppIcon";
import { AppMenuCloseButton } from "../../components/AppMenuControls";
import { useModalDialog } from "../../components/useModalDialog";
import type {
  ConnectionStatus,
  Conversation,
  UserCapabilities
} from "../../types";
import { CallLaunchActions, CallLaunchButton } from "../calls/CallSessionProvider";
import { canCreateGuestLink } from "../guest/ConversationShareDialog";
import {
  connectionLabel,
  conversationInitials
} from "./chatSupport";
import "./ConversationWorkspace.css";

export function ConversationWorkspaceHeader({
  conversation,
  title,
  connectionStatus,
  onlineUsers,
  capabilities,
  audioCallsAvailable,
  videoCallsAvailable,
  callGuidance,
  callInProgress = false,
  mobileBackRef,
  showSearch,
  showActivity,
  showDetails,
  onShowConversationList,
  onToggleSearch,
  onInviteGuest,
  onToggleActivity,
  onToggleDetails
}: {
  conversation: Conversation;
  title: string;
  connectionStatus: ConnectionStatus;
  onlineUsers: number;
  capabilities: UserCapabilities | null;
  audioCallsAvailable: boolean;
  videoCallsAvailable: boolean;
  callGuidance: string | null;
  callInProgress?: boolean;
  mobileBackRef: RefObject<HTMLButtonElement | null>;
  showSearch: boolean;
  showActivity: boolean;
  showDetails: boolean;
  onShowConversationList: () => void;
  onToggleSearch: () => void;
  onInviteGuest: () => void;
  onToggleActivity: () => void;
  onToggleDetails: () => void;
}) {
  const [moreOpen, setMoreOpen] = useState(false);
  const canInvite =
    conversation.kind === "direct" || canCreateGuestLink(conversation);
  const canvasHref = `/app/whiteboard?conversation=${encodeURIComponent(
    conversation.id
  )}`;
  const chatHref = `/app/?conversation=${encodeURIComponent(conversation.id)}`;

  return (
    <header className="conversation-header">
      <div className="conversation-header-main">
        <button
          ref={mobileBackRef}
          className="mobile-back"
          type="button"
          onClick={onShowConversationList}
          aria-label="Back to conversations"
        >
          <AppIcon name="arrowLeft" />
        </button>

        <div className="conversation-identity">
          <span className="conversation-avatar" aria-hidden="true">
            {conversationInitials(title)}
          </span>
          <div className="conversation-title-copy">
            <h2 data-route-focus>{title}</h2>
            <div className="conversation-title-meta">
              <span>{conversationKindLabel(conversation)}</span>
              <span aria-hidden="true">·</span>
              <span>{conversation.visibility}</span>
              <div className="connection-summary" aria-live="polite">
                <span
                  className={`status-dot ${connectionStatus}`}
                  aria-hidden="true"
                />
                <span>{connectionLabel(connectionStatus)}</span>
                {onlineUsers > 0 && <small>{onlineUsers} online</small>}
              </div>
            </div>
          </div>
        </div>

        <div className="conversation-header-actions">
          <button
            className="conversation-header-icon"
            type="button"
            aria-label="Search messages"
            aria-expanded={showSearch}
            onClick={onToggleSearch}
          >
            <AppIcon name="search" />
          </button>
          <CallLaunchActions
            conversation={conversation}
            audioEnabled={
              capabilities?.allow_audio_calls === true &&
              audioCallsAvailable
            }
            videoEnabled={
              capabilities?.allow_video_calls === true &&
              videoCallsAvailable
            }
            availabilityDescriptionId={
              callGuidance ? "conversation-call-availability" : undefined
            }
            iconOnly
          />
          {canInvite && (
            <button
              className="conversation-header-icon"
              type="button"
              aria-haspopup="dialog"
              aria-label="Invite guest"
              onClick={onInviteGuest}
            >
              <AppIcon name="userPlus" />
            </button>
          )}
          <button
            className="conversation-header-icon conversation-more-trigger"
            type="button"
            aria-haspopup="dialog"
            aria-expanded={moreOpen}
            aria-controls="conversation-more-sheet"
            aria-label="More conversation actions"
            onClick={() => setMoreOpen(true)}
          >
            <AppIcon name="more" />
          </button>
        </div>
      </div>

      <nav
        className="conversation-section-nav"
        aria-label="Conversation workspace"
      >
        <Link className="active" to={chatHref} aria-current="page">
          <AppIcon name="message" />
          Chat
        </Link>
        <Link to={canvasHref}>
          <AppIcon name="whiteboard" />
          Canvas
        </Link>
        <button
          type="button"
          aria-expanded={showActivity}
          aria-controls="conversation-activity-panel"
          onClick={onToggleActivity}
        >
          <AppIcon name="activity" />
          Activity
        </button>
        <button
          type="button"
          aria-expanded={showDetails}
          aria-controls="conversation-details-panel"
          onClick={onToggleDetails}
        >
          <AppIcon name="users" />
          Details
        </button>
      </nav>
      {/*
        * The conversation list marks rooms with a call running; the open room
        * did not say so anywhere. This strip is that missing state, and only
        * that state: ChatPage withholds it once you are in the call, because
        * the call dock is already on screen saying the same thing with a
        * control to return to it.
        */}
      {callInProgress && (
        <div className="conversation-call-strip" role="status">
          <span className="conversation-call-strip-state">
            <AppIcon name="phone" />
            A call is running in this conversation
          </span>
          {audioCallsAvailable && (
            <CallLaunchButton
              conversation={conversation}
              kind="audio"
              className="button primary compact conversation-call-strip-join"
              ariaLabel={`Join the call in ${title}`}
            >
              Join
            </CallLaunchButton>
          )}
        </div>
      )}
      {moreOpen && (
        <ConversationMoreSheet
          canvasHref={canvasHref}
          canInvite={canInvite}
          onClose={() => setMoreOpen(false)}
          onInviteGuest={onInviteGuest}
          onToggleActivity={onToggleActivity}
          onToggleDetails={onToggleDetails}
          onToggleSearch={onToggleSearch}
        />
      )}
    </header>
  );
}

/*
 * The phone header used to be two rows — identity above a four-item section
 * strip — which cost 106px before a single message. Chat is where you already
 * are, so it needs no tab; the other three surfaces plus search and guest
 * invites live here instead, one tap deeper, and the header collapses to one
 * row.
 */
function ConversationMoreSheet({
  canvasHref,
  canInvite,
  onClose,
  onInviteGuest,
  onToggleActivity,
  onToggleDetails,
  onToggleSearch
}: {
  canvasHref: string;
  canInvite: boolean;
  onClose: () => void;
  onInviteGuest: () => void;
  onToggleActivity: () => void;
  onToggleDetails: () => void;
  onToggleSearch: () => void;
}) {
  const dialogRef = useModalDialog(onClose);
  const run = (action: () => void) => () => {
    onClose();
    action();
  };

  return createPortal(
    <div
      className="modal-backdrop conversation-more-backdrop"
      onPointerDown={(event) => {
        if (event.currentTarget === event.target) onClose();
      }}
    >
      <section
        ref={dialogRef}
        className="conversation-more-sheet"
        id="conversation-more-sheet"
        role="dialog"
        aria-modal="true"
        aria-labelledby="conversation-more-title"
      >
        <header>
          <h2 id="conversation-more-title">Conversation</h2>
          <AppMenuCloseButton
            data-initial-focus
            accessibleLabel="Close conversation actions"
            onClick={onClose}
          />
        </header>
        <Link to={canvasHref} onClick={onClose}>
          <AppIcon name="whiteboard" />
          Canvas
        </Link>
        <button type="button" onClick={run(onToggleActivity)}>
          <AppIcon name="activity" />
          Activity
        </button>
        <button type="button" onClick={run(onToggleDetails)}>
          <AppIcon name="users" />
          Details
        </button>
        <button type="button" onClick={run(onToggleSearch)}>
          <AppIcon name="search" />
          Search messages
        </button>
        {canInvite && (
          <button type="button" onClick={run(onInviteGuest)}>
            <AppIcon name="userPlus" />
            Invite guest
          </button>
        )}
      </section>
    </div>,
    document.body
  );
}

function conversationKindLabel(conversation: Conversation): string {
  if (conversation.kind === "direct") return "Direct message";
  if (conversation.kind === "group") return "Group conversation";
  return "Channel";
}
