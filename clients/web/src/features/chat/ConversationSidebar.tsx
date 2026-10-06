import { useSyncExternalStore } from "react";
import type { MutableRefObject, ReactNode } from "react";
import { useSession } from "../../app/session";
import { draftSnapshot, localDraftPreview, subscribeDrafts } from "../../lib/drafts";
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
import { useDesktopShell } from "../../app/ProductShell";
import { NotificationCenter } from "../notifications/NotificationCenter";

export type InboxFilter = "all" | "unread" | "favorites" | "direct" | "rooms";

interface ConversationSidebarProps {
  activeConversationId: string | null;
  composer: string;
  pendingFavoriteId: string | null;
  favoriteError: string | null;
  onToggleFavorite: (conversation: Conversation) => void;
  activeCallConversationIds: ReadonlySet<string>;
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
  setupGuide?: ReactNode;
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
  composer,
  pendingFavoriteId,
  favoriteError,
  onToggleFavorite,
  activeCallConversationIds,
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
  setupGuide,
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
  const desktopShell = useDesktopShell();
  const { session } = useSession();
  useSyncExternalStore(subscribeDrafts, draftSnapshot, draftSnapshot);
  const contentSearchButton = (
    <button
      className="button ghost inbox-content-search"
      type="button"
      aria-label="Search workspace content"
      title="Search messages, files, and whiteboards"
      aria-expanded={showSearch}
      onClick={onToggleSearch}
    >
      <AppIcon name="search" />
      <span>{desktopShell ? "Search" : "Search workspace content"}</span>
    </button>
  );
  return (
    <aside className="conversation-sidebar" aria-label="Conversations">
      <div className="sidebar-heading">
        <div className="sidebar-title-row">
          <div className="sidebar-heading-title">
            <span className="eyebrow">Messages and rooms</span>
            <span className="sidebar-title-line">
              <h1>Inbox</h1>
              {conversations.length > 0 && (
                <span
                  className="sidebar-result-count"
                  aria-label={`${filteredConversations.length} ${filteredConversations.length === 1 ? "conversation" : "conversations"} shown`}
                >
                  {filteredConversations.length}
                </span>
              )}
            </span>
          </div>
          <div className="sidebar-tools">
            {desktopShell && contentSearchButton}
            {/*
              * Notifications sat in the global phone top bar until that bar was
              * removed. They belong here rather than in a bar of their own: in a
              * communication product every notification is about a message or a
              * mention, so the inbox is the surface they are already about.
              */}
            {!desktopShell && <NotificationCenter conversations={conversations} />}
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
        {conversations.length > 0 && (
          <div className="sidebar-search" role="search" aria-label="Search conversations">
            <label className="sr-only" htmlFor="conversation-filter-query">
              Filter conversation titles
            </label>
            <AppIcon name="search" className="sidebar-search-glyph" />
            <input
              id="conversation-filter-query"
              type="search"
              value={conversationQuery}
              onChange={(event) => onConversationQueryChange(event.target.value)}
              placeholder="Filter conversation titles"
            />
          </div>
        )}
        {!desktopShell && contentSearchButton}
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
          <div className="onboarding-optional-checks" aria-label="Optional setup checks">
            <Link to="/app/you?section=audio-video">Check audio &amp; video</Link>
            <Link to="/app/you?section=notifications">Set up notifications</Link>
            <button className="text-button" type="button" onClick={onDismissOnboarding}>Skip for now</button>
          </div>
        </section>
      )}

      {setupGuide}

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

      {/*
        * The row itself is unconditional: browsing channels is the one action
        * that helps most on an empty inbox, so it must not disappear with the
        * scope chips. Filtering a list of nothing is what is meaningless, not
        * finding something to join.
        */}
      <div className="conversation-filters">
        {conversations.length > 0 && (
          <div
            className="inbox-segments"
            role="group"
            aria-label="Inbox view"
          >
            {([
              ["all", "All"],
              ["unread", "Unread"],
              ["favorites", "Favorites"],
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
        )}
        <button
          className="icon-button inbox-filter-trigger"
          type="button"
          aria-label="Browse channels"
          aria-expanded={showBrowseChannels}
          onClick={onToggleBrowseChannels}
        >
          <AppIcon name="compass" />
        </button>
      </div>

      {favoriteError && <p className="error-copy" role="alert">{favoriteError}</p>}
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
            const hasActiveCall = activeCallConversationIds.has(conversation.id);
            const draft = conversation.id === activeConversationId ? composer : session
              ? localDraftPreview(session.tenant.id, session.user.id, conversation.id) ??
                (conversation.inbox?.draft && Date.parse(conversation.inbox.draft.expires_at) > Date.now() ? conversation.inbox.draft.excerpt : "")
              : "";
            const message = conversation.inbox?.message;
            const activityAt = message?.inserted_at ?? conversation.updated_at;
            const preview = draft.trim() ? `Draft: ${draft.trim().replace(/\s+/g, " ").slice(0, 200)}`
              : message ? message.status !== "active" ? "Message removed"
                : `${message.sender_user_id === session?.user.id ? "You" : message.sender_display_name}: ${message.excerpt.trim() || "Shared content"}`
              : conversation.latest_sequence === 0 ? "No messages yet"
                : conversation.kind === "direct" ? "Direct message" : conversation.kind === "channel" ? "Room conversation" : "Group conversation";
            return (
              <div key={conversation.id} className="conversation-list-item">
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
                      dateTime={activityAt}
                      title={formatDateTime(activityAt)}
                    >
                      {formatTime(activityAt)}
                    </time>
                  </span>
                  <small className={`conversation-summary-line ${draft.trim() ? "has-draft" : ""}`}>
                    <span>
                      {preview}
                    </span>
                    {hasActiveCall && (
                      <span className="conversation-live-call">
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
              {conversation.content_mode !== "matrix_e2ee" && (
                <button type="button" className="icon-button conversation-favorite"
                  aria-label={`${conversation.favorite ? "Remove" : "Add"} ${conversationIdentifier(conversation)} ${conversation.favorite ? "from" : "to"} favorites`}
                  aria-pressed={conversation.favorite === true}
                  disabled={pendingFavoriteId !== null}
                  aria-busy={pendingFavoriteId === conversation.id}
                  onClick={() => onToggleFavorite(conversation)}>
                  <AppIcon name="star" fill={conversation.favorite ? "currentColor" : "none"} />
                </button>
              )}
              </div>
            );
          })
        )}
      </nav>
    </aside>
  );
}
