import type { MutableRefObject } from "react";
import { Link } from "react-router";
import type { CreateConversationInput } from "../../api";
import { AppIcon } from "../../components/AppIcon";
import { formatDateTime, formatTime } from "../../lib/format";
import {
  participantIdentifier
} from "../../lib/participantIdentity";
import type {
  Conversation,
  User,
  UserCapabilities
} from "../../types";
import { CreateConversationForm } from "./CreateConversationForm";
import { conversationInitials } from "./chatSupport";

export type InboxFilter = "all" | "unread" | "direct" | "rooms";

interface ConversationSidebarProps {
  activeConversationId: string | null;
  activeCallConversationId: string | null;
  capabilities: UserCapabilities | null;
  canInviteTeammates: boolean;
  conversations: Conversation[];
  filteredConversations: Conversation[];
  conversationUsers: User[];
  conversationQuery: string;
  inboxFilter: InboxFilter;
  showBrowseChannels: boolean;
  showCreateConversation: boolean;
  showOnboardingSpotlight: boolean;
  showSearch: boolean;
  needsFirstTeammate: boolean;
  needsTeammateAccessReview: boolean;
  humanTeammates: User[];
  duplicateTeammateNames: ReadonlySet<string>;
  directStartingUserId: string | null;
  conversationButtonRefs: MutableRefObject<
    Map<string, HTMLButtonElement>
  >;
  conversationIdentifier: (conversation: Conversation) => string;
  onConversationQueryChange: (query: string) => void;
  onInboxFilterChange: (filter: InboxFilter) => void;
  onToggleBrowseChannels: () => void;
  onToggleSearch: () => void;
  onToggleCreateConversation: () => void;
  onDismissOnboarding: () => void;
  onStartDirect: (userId: string) => Promise<void>;
  onCreate: (input: CreateConversationInput) => Promise<void>;
  onSelectConversation: (conversationId: string) => void;
  onShowCreateConversation: () => void;
  onShowBrowseChannels: () => void;
}

const invitationPath = "/admin?section=people#admin-invitations";
const peoplePath = "/admin?section=people#people-title";

export function ConversationSidebar({
  activeConversationId,
  activeCallConversationId,
  capabilities,
  canInviteTeammates,
  conversations,
  filteredConversations,
  conversationUsers,
  conversationQuery,
  inboxFilter,
  showBrowseChannels,
  showCreateConversation,
  showOnboardingSpotlight,
  showSearch,
  needsFirstTeammate,
  needsTeammateAccessReview,
  humanTeammates,
  duplicateTeammateNames,
  directStartingUserId,
  conversationButtonRefs,
  conversationIdentifier,
  onConversationQueryChange,
  onInboxFilterChange,
  onToggleBrowseChannels,
  onToggleSearch,
  onToggleCreateConversation,
  onDismissOnboarding,
  onStartDirect,
  onCreate,
  onSelectConversation,
  onShowCreateConversation,
  onShowBrowseChannels
}: ConversationSidebarProps) {
  return (
    <aside className="conversation-sidebar" aria-label="Conversations">
      <div className="sidebar-heading">
        <div>
          <span className="eyebrow">Messages and rooms</span>
          <h1>Inbox</h1>
        </div>
        <div className="sidebar-tools">
          <button
            className="icon-button inbox-filter-trigger"
            type="button"
            aria-label="Browse channels"
            aria-expanded={showBrowseChannels}
            onClick={onToggleBrowseChannels}
          >
            <AppIcon name="compass" />
          </button>
          <button
            className="icon-button inbox-search-trigger"
            type="button"
            aria-label="Search messages"
            aria-expanded={showSearch}
            onClick={onToggleSearch}
          >
            <AppIcon name="search" />
          </button>
          <button
            className="icon-button inbox-new-button"
            type="button"
            aria-label="Create conversation"
            aria-expanded={showCreateConversation}
            onClick={onToggleCreateConversation}
          >
            <AppIcon name="plus" />
            <span>New</span>
          </button>
        </div>
      </div>

      {showOnboardingSpotlight && (
        <section
          className="onboarding-spotlight"
          aria-labelledby="onboarding-spotlight-title"
        >
          <div className="onboarding-spotlight-heading">
            <div>
              <span className="eyebrow">Quick start</span>
              <h2 id="onboarding-spotlight-title">
                {needsFirstTeammate
                  ? "Bring in your teammate"
                  : needsTeammateAccessReview
                    ? "Reconnect your teammate"
                    : humanTeammates.length > 0
                      ? "Start your first conversation"
                      : "Your workspace is ready"}
              </h2>
            </div>
            <button
              type="button"
              aria-label="Dismiss welcome guide"
              onClick={onDismissOnboarding}
            >
              <AppIcon name="x" />
            </button>
          </div>
          <p>
            {needsFirstTeammate
              ? "Invite one person, then message or call from the same conversation."
              : needsTeammateAccessReview
                ? "Review the existing inactive account before sending another invitation."
                : humanTeammates.length > 0
                  ? "Message a teammate now—there is no setup form."
                  : capabilities?.allow_public_channels === true
                    ? "Browse a room to start messaging."
                    : "An administrator needs to add you to a room or teammate conversation."}
          </p>
          <div className="onboarding-spotlight-actions">
            {needsFirstTeammate ? (
              <Link className="button primary compact" to={invitationPath}>
                Invite your first teammate
              </Link>
            ) : needsTeammateAccessReview ? (
              <Link className="button primary compact" to={peoplePath}>
                Manage teammate access
              </Link>
            ) : humanTeammates.length > 0 ? (
              humanTeammates.slice(0, 3).map((user) => (
                <button
                  className="button primary compact"
                  type="button"
                  key={user.id}
                  aria-busy={directStartingUserId === user.id}
                  disabled={directStartingUserId !== null}
                  onClick={() => void onStartDirect(user.id)}
                >
                  {directStartingUserId === user.id
                    ? `Opening ${participantIdentifier(user, duplicateTeammateNames)}…`
                    : `Message ${participantIdentifier(user, duplicateTeammateNames)}`}
                </button>
              ))
            ) : capabilities?.allow_public_channels === true ? (
              <button
                className="button primary compact"
                type="button"
                onClick={onShowBrowseChannels}
              >
                Browse rooms
              </button>
            ) : null}
          </div>
          <small>
            Notification preferences remain available anytime under You.
          </small>
        </section>
      )}

      {showCreateConversation && (
        <CreateConversationForm
          users={conversationUsers}
          allowPublicChannels={
            capabilities?.allow_public_channels === true
          }
          emptyDirectAction={
            canInviteTeammates ? (
              <Link
                className="button ghost compact"
                to={invitationPath}
              >
                Invite your first teammate
              </Link>
            ) : undefined
          }
          onCancel={onToggleCreateConversation}
          onCreate={onCreate}
          onStartDirect={onStartDirect}
        />
      )}

      {conversations.length > 0 && (
        <div
          className="conversation-filters"
          role="search"
          aria-label="Filter conversations"
        >
          <label
            className="sr-only"
            htmlFor="conversation-filter-query"
          >
            Filter conversations by title
          </label>
          <input
            id="conversation-filter-query"
            type="search"
            value={conversationQuery}
            onChange={(event) =>
              onConversationQueryChange(event.target.value)
            }
            placeholder="Search inbox"
          />
          <div
            className="inbox-segments"
            role="group"
            aria-label="Inbox view"
          >
            {([
              ["all", "All"],
              ["unread", "Unread"],
              ["direct", "Direct"],
              ["rooms", "Rooms"]
            ] as const).map(([value, label]) => (
              <button
                className="inbox-segment"
                type="button"
                key={value}
                aria-pressed={inboxFilter === value}
                onClick={() => onInboxFilterChange(value)}
              >
                {label}
              </button>
            ))}
          </div>
        </div>
      )}

      <nav className="conversation-list" aria-label="Conversation list">
        {conversations.length === 0 ? (
          showOnboardingSpotlight ? (
            <p className="empty-copy">Your conversations will appear here.</p>
          ) : (
            <div className="conversation-zero-state">
              <p className="empty-copy">
                No conversations yet. Choose how you want to get started.
              </p>
              <div className="empty-state-actions">
                <button
                  className="button primary compact"
                  type="button"
                  onClick={onShowCreateConversation}
                >
                  Start a conversation
                </button>
                <button
                  className="button ghost compact"
                  type="button"
                  onClick={onShowBrowseChannels}
                >
                  Browse channels
                </button>
                {canInviteTeammates && (
                  <Link
                    className="button ghost compact"
                    to={invitationPath}
                  >
                    Invite a teammate
                  </Link>
                )}
              </div>
            </div>
          )
        ) : filteredConversations.length === 0 ? (
          <p className="empty-copy" role="status">
            No conversations match these filters.
          </p>
        ) : (
          filteredConversations.map((conversation) => {
            const unreadCount = conversation.unread_count || 0;
            const hasActiveCall = conversation.id === activeCallConversationId;
            return (
              <button
                ref={(element) => {
                  if (element) {
                    conversationButtonRefs.current.set(
                      conversation.id,
                      element
                    );
                  } else {
                    conversationButtonRefs.current.delete(conversation.id);
                  }
                }}
                type="button"
                key={conversation.id}
                className={`conversation-row ${unreadCount > 0 ? "unread" : ""} ${hasActiveCall ? "has-active-call" : ""} ${
                  conversation.id === activeConversationId ? "active" : ""
                }`}
                aria-current={
                  conversation.id === activeConversationId
                    ? "page"
                    : undefined
                }
                onClick={() => onSelectConversation(conversation.id)}
              >
                <span
                  className={`conversation-icon ${conversation.kind}`}
                  aria-hidden="true"
                >
                  {conversation.kind === "channel" ? (
                    <AppIcon name="hash" />
                  ) : conversation.kind === "direct" ? (
                    conversationInitials(
                      conversationIdentifier(conversation)
                    )
                  ) : (
                    <AppIcon name="users" />
                  )}
                </span>
                <span className="conversation-copy">
                  <span className="conversation-title-line">
                    <strong>{conversationIdentifier(conversation)}</strong>
                    <time
                      dateTime={conversation.updated_at}
                      title={formatDateTime(conversation.updated_at)}
                    >
                      {formatTime(conversation.updated_at)}
                    </time>
                  </span>
                  <small className="conversation-summary-line">
                    <span>
                      {conversation.kind === "direct"
                        ? "Direct message"
                        : conversation.kind === "channel"
                          ? "Room conversation"
                          : "Group conversation"}
                    </span>
                    {hasActiveCall && (
                      <span className="conversation-call-state">
                        <AppIcon name="phone" />
                        Active call
                      </span>
                    )}
                    {unreadCount > 0 && (
                      <span
                        className="conversation-unread-copy"
                        aria-hidden="true"
                      >
                        {unreadCount} unread
                      </span>
                    )}
                  </small>
                </span>
                {unreadCount > 0 && (
                  <span
                    className="unread-badge"
                    aria-label={`${unreadCount} unread messages`}
                  >
                    {unreadCount}
                  </span>
                )}
              </button>
            );
          })
        )}
      </nav>
    </aside>
  );
}
