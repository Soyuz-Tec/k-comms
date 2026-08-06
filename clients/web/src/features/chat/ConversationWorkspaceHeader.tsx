import type { RefObject } from "react";
import { Link } from "react-router";
import { AppIcon } from "../../components/AppIcon";
import type {
  ConnectionStatus,
  Conversation,
  UserCapabilities
} from "../../types";
import { CallLaunchActions } from "../calls/CallSessionProvider";
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
  const canInvite =
    conversation.kind === "direct" || canCreateGuestLink(conversation);
  const canvasHref = `/app/whiteboard?conversation=${encodeURIComponent(
    conversation.id
  )}`;

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
        </div>
      </div>

      <nav
        className="conversation-section-nav"
        aria-label="Conversation workspace"
      >
        <span className="active" aria-current="page">
          <AppIcon name="message" />
          Chat
        </span>
        <Link to={canvasHref}>
          <AppIcon name="whiteboard" />
          Canvas
        </Link>
        <button
          type="button"
          aria-expanded={showActivity}
          onClick={onToggleActivity}
        >
          <AppIcon name="activity" />
          Activity
        </button>
        <button
          type="button"
          aria-expanded={showDetails}
          onClick={onToggleDetails}
        >
          <AppIcon name="users" />
          Details
        </button>
      </nav>
    </header>
  );
}

function conversationKindLabel(conversation: Conversation): string {
  if (conversation.kind === "direct") return "Direct message";
  if (conversation.kind === "group") return "Group conversation";
  return "Channel";
}
