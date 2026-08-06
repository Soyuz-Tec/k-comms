import { Fragment } from "react";
import type {
  ChangeEvent,
  ComponentProps,
  FormEvent,
  RefObject
} from "react";
import { Link } from "react-router";
import { AppIcon } from "../../components/AppIcon";
import { dayKey, formatDayLabel } from "../../lib/format";
import type {
  ConnectionStatus,
  Conversation,
  ConversationMembership,
  Message,
  MessageDeliveryCursor,
  WhiteboardMessageReference,
  UserCapabilities
} from "../../types";
import {
  AttachmentUploadList,
  type PendingAttachmentUpload
} from "./AttachmentUploadList";
import { ConversationWorkspaceHeader } from "./ConversationWorkspaceHeader";
import { MentionPicker } from "./MentionPicker";
import { MessageItem } from "./MessageItem";
import type { FailedChatSend } from "./useChatComposer";

type RequestThumbnail = ComponentProps<
  typeof MessageItem
>["onRequestThumbnail"];

export function ConversationPane({
  activeConversation,
  activeTyping,
  attachmentsReady,
  audioCallsAvailable,
  callGuidance,
  capabilities,
  composer,
  connectionStatus,
  conversationIdentifier,
  currentUserId,
  failedSend,
  focusTargetId,
  hasOlder,
  isNearBottom,
  members,
  mentionedUserIds,
  messages,
  messagesEndRef,
  messagesLoading,
  mobileBackRef,
  newMessageCount,
  olderLoading,
  onlineUsers,
  pendingAttachments,
  readCursors,
  deliveryCursors,
  whiteboardReference,
  replyTo,
  scrollRef,
  sending,
  showDetails,
  showActivity,
  showSearch,
  uploading,
  videoCallsAvailable,
  visibleSenderIdentifier,
  onAttachmentCancel,
  onAttachmentRetry,
  onComposerChange,
  onDelete,
  onEdit,
  onFilesSelected,
  onInviteGuest,
  onJumpToLatest,
  onLoadOlder,
  onMentionedUserIdsChange,
  onOpenAttachment,
  onReaction,
  onReply,
  onReport,
  onRequestThumbnail,
  onRetrySend,
  onScroll,
  onSend,
  onShowConversationList,
  onThread,
  onToggleDetails,
  onToggleActivity,
  onToggleSearch,
  onClearWhiteboardReference,
  setReplyTo
}: {
  activeConversation: Conversation | null;
  activeTyping: string[];
  attachmentsReady: boolean;
  audioCallsAvailable: boolean;
  callGuidance: string | null;
  capabilities: UserCapabilities | null;
  composer: string;
  connectionStatus: ConnectionStatus;
  conversationIdentifier: (conversation: Conversation) => string;
  currentUserId: string;
  failedSend: FailedChatSend | null;
  focusTargetId: string | null;
  hasOlder: boolean;
  isNearBottom: boolean;
  members: ConversationMembership[];
  mentionedUserIds: string[];
  messages: Message[];
  messagesEndRef: RefObject<HTMLDivElement | null>;
  messagesLoading: boolean;
  mobileBackRef: RefObject<HTMLButtonElement | null>;
  newMessageCount: number;
  olderLoading: boolean;
  onlineUsers: number;
  pendingAttachments: PendingAttachmentUpload[];
  readCursors: Record<string, number>;
  deliveryCursors: MessageDeliveryCursor[];
  whiteboardReference: WhiteboardMessageReference | null;
  replyTo: Message | null;
  scrollRef: RefObject<HTMLDivElement | null>;
  sending: boolean;
  showDetails: boolean;
  showActivity: boolean;
  showSearch: boolean;
  uploading: boolean;
  videoCallsAvailable: boolean;
  visibleSenderIdentifier: (userId: string) => string | undefined;
  onAttachmentCancel: (clientId: string) => void;
  onAttachmentRetry: (clientId: string) => void;
  onComposerChange: (event: ChangeEvent<HTMLTextAreaElement>) => void;
  onDelete: (message: Message) => Promise<void>;
  onEdit: (message: Message, body: string) => Promise<void>;
  onFilesSelected: (event: ChangeEvent<HTMLInputElement>) => Promise<void>;
  onInviteGuest: () => void;
  onJumpToLatest: () => void;
  onLoadOlder: (scroll: HTMLDivElement | null) => Promise<void>;
  onMentionedUserIdsChange: (ids: string[]) => void;
  onOpenAttachment: ComponentProps<typeof MessageItem>["onAttachment"];
  onReaction: (message: Message, emoji: string) => void;
  onReply: (message: Message) => void;
  onReport: (message: Message) => void;
  onRequestThumbnail: RequestThumbnail;
  onRetrySend: () => Promise<void>;
  onScroll: () => void;
  onSend: (event: FormEvent<HTMLFormElement>) => Promise<void>;
  onShowConversationList: () => void;
  onThread: (message: Message) => void;
  onToggleDetails: () => void;
  onToggleActivity: () => void;
  onToggleSearch: () => void;
  onClearWhiteboardReference: () => void;
  setReplyTo: (message: Message | null) => void;
}) {
  const title = activeConversation
    ? conversationIdentifier(activeConversation)
    : "Messages";
  const messagesById = new Map(
    messages.map((message) => [message.id, message])
  );

  return (
    <section className="conversation-pane" aria-label={title}>
      {activeConversation ? (
        <>
          <ConversationWorkspaceHeader
            conversation={activeConversation}
            title={title}
            connectionStatus={connectionStatus}
            onlineUsers={onlineUsers}
            capabilities={capabilities}
            audioCallsAvailable={audioCallsAvailable}
            videoCallsAvailable={videoCallsAvailable}
            callGuidance={callGuidance}
            mobileBackRef={mobileBackRef}
            showSearch={showSearch}
            showActivity={showActivity}
            showDetails={showDetails}
            onShowConversationList={onShowConversationList}
            onToggleSearch={onToggleSearch}
            onInviteGuest={onInviteGuest}
            onToggleActivity={onToggleActivity}
            onToggleDetails={onToggleDetails}
          />
          {callGuidance && (
            <p
              className="call-availability-guidance conversation-call-guidance"
              id="conversation-call-availability"
              role="status"
            >
              <span>{callGuidance}</span>
              <Link to="/app/calls">Open Calls</Link>
            </p>
          )}
          <div
            className="message-scroll"
            ref={scrollRef}
            aria-busy={messagesLoading}
            onScroll={onScroll}
          >
            {hasOlder && (
              <div className="history-loader">
                <button
                  className="button ghost compact"
                  type="button"
                  disabled={olderLoading}
                  onClick={() => void onLoadOlder(scrollRef.current)}
                >
                  {olderLoading ? "Loading…" : "Load older messages"}
                </button>
              </div>
            )}
            {messagesLoading && messages.length === 0 ? (
              <div className="inline-loading">
                <span className="spinner" aria-hidden="true" />
                Loading messages…
              </div>
            ) : messages.length === 0 ? (
              <div className="empty-state">
                <span className="empty-mark" aria-hidden="true">
                  <AppIcon name="sparkles" />
                </span>
                <h3>Start the conversation</h3>
                <p>
                  Messages are durable, ordered, and replayed when you
                  reconnect.
                </p>
              </div>
            ) : (
              <ol className="message-list">
                {messages.map((message, index) => {
                  const previousMessage =
                    index > 0 ? messages[index - 1] : undefined;
                  const startsDay =
                    !previousMessage ||
                    dayKey(previousMessage.inserted_at) !==
                      dayKey(message.inserted_at);
                  const replyPreview = message.reply_to_message_id
                    ? messagesById.get(message.reply_to_message_id)
                    : undefined;
                  const senderName = visibleSenderIdentifier(
                    message.sender_user_id
                  );
                  const replySenderName = replyPreview
                    ? visibleSenderIdentifier(replyPreview.sender_user_id)
                    : undefined;
                  return (
                    <Fragment key={message.id}>
                      {startsDay && (
                        <li className="day-divider">
                          <span>{formatDayLabel(message.inserted_at)}</span>
                        </li>
                      )}
                      <MessageItem
                        message={message}
                        currentUserId={currentUserId}
                        senderName={senderName}
                        replyPreview={replyPreview}
                        replySenderName={replySenderName}
                        seenCount={
                          Object.entries(readCursors).filter(
                            ([userId, sequence]) =>
                              userId !== currentUserId &&
                              sequence >= message.conversation_sequence
                          ).length
                        }
                        deliveredDeviceCount={deliveryCursors.filter((cursor) => cursor.recipient_user_id !== currentUserId && cursor.delivered_sequence >= message.conversation_sequence).length}
                        focused={focusTargetId === message.id}
                        onReaction={(emoji) => onReaction(message, emoji)}
                        onAttachment={onOpenAttachment}
                        onRequestThumbnail={onRequestThumbnail}
                        onReply={() => onReply(message)}
                        onThread={() => onThread(message)}
                        onEdit={(body) => onEdit(message, body)}
                        onDelete={() => onDelete(message)}
                        onReport={() => onReport(message)}
                      />
                    </Fragment>
                  );
                })}
              </ol>
            )}
            <div ref={messagesEndRef} />
          </div>
          <p
            className="sr-only"
            role="status"
            aria-live="polite"
            aria-atomic="true"
          >
            {newMessageCount > 0
              ? `${newMessageCount} new ${
                  newMessageCount === 1 ? "message" : "messages"
                }.`
              : ""}
          </p>
          {!isNearBottom && (
            <div className="new-message-jump">
              <button
                className="button primary compact"
                type="button"
                onClick={onJumpToLatest}
              >
                {newMessageCount > 0
                  ? `${newMessageCount} new ${
                      newMessageCount === 1 ? "message" : "messages"
                    } · Jump to latest`
                  : "Jump to latest"}
              </button>
            </div>
          )}
          <div className="typing-line" aria-live="polite">
            {activeTyping.length > 0
              ? `${activeTyping.join(", ")} ${
                  activeTyping.length === 1 ? "is" : "are"
                } typing…`
              : "\u00a0"}
          </div>
          <form
            className="composer"
            onSubmit={(event) => void onSend(event)}
          >
            {failedSend && (
              <div className="failed-send" role="alert">
                <span>
                  Message not sent. Your draft is safe. {failedSend.error}
                </span>
                <button
                  className="button ghost compact"
                  type="button"
                  disabled={sending}
                  onClick={() => void onRetrySend()}
                >
                  Retry
                </button>
              </div>
            )}
            {replyTo && (
              <div className="composer-reply">
                <span>
                  Replying to{" "}
                  <strong>
                    {replyTo.sender_user_id === currentUserId
                      ? "yourself"
                      : visibleSenderIdentifier(replyTo.sender_user_id) ||
                        "a message"}
                  </strong>
                  <small>{replyTo.body}</small>
                </span>
                <button
                  type="button"
                  aria-label="Cancel reply"
                  onClick={() => setReplyTo(null)}
                >
                  <AppIcon name="x" />
                </button>
              </div>
            )}
            {whiteboardReference && (
              <div className="composer-reply composer-whiteboard-reference">
                <span><strong>{whiteboardReference.label || "Whiteboard selection"}</strong><small>{whiteboardReference.element_ids.length} referenced {whiteboardReference.element_ids.length === 1 ? "object" : "objects"}</small></span>
                <button type="button" aria-label="Remove whiteboard reference" onClick={onClearWhiteboardReference}><AppIcon name="x" /></button>
              </div>
            )}
            {pendingAttachments.length > 0 && (
              <AttachmentUploadList
                items={pendingAttachments}
                onCancel={onAttachmentCancel}
                onRetry={onAttachmentRetry}
              />
            )}
            <div className="composer-heading">
              <span>
                <AppIcon name="message" />
                <strong>Message {title}</strong>
              </span>
              <span className="composer-draft-state">
                <AppIcon name="check" />
                Draft saved on this device
              </span>
            </div>
            <div className="composer-shell">
              <label className="sr-only" htmlFor="message-composer">
                Message
              </label>
              <textarea
                id="message-composer"
                value={composer}
                onChange={onComposerChange}
                onKeyDown={(event) => {
                  if (event.key === "Enter" && !event.shiftKey) {
                    event.preventDefault();
                    event.currentTarget.form?.requestSubmit();
                  }
                }}
                rows={1}
                maxLength={65_535}
                placeholder={`Message ${title}`}
                disabled={sending}
              />
              <div className="composer-inline-actions">
                <label
                  className={`attachment-button composer-icon-button ${
                    sending ? "disabled" : ""
                  }`}
                >
                  <input
                    type="file"
                    multiple
                    disabled={sending}
                    onChange={(event) => void onFilesSelected(event)}
                    accept="image/*,text/*,application/pdf,application/zip,application/json"
                    aria-label="Attach files"
                  />
                  <AppIcon name="paperclip" />
                </label>
                <button
                  className="composer-icon-button composer-send send-button"
                  type="submit"
                  aria-label={sending ? "Sending message" : "Send message"}
                  disabled={
                    sending ||
                    uploading ||
                    !attachmentsReady ||
                    !composer.trim()
                  }
                >
                  <AppIcon
                    className={sending ? "spin" : ""}
                    name={sending ? "loader" : "send"}
                  />
                </button>
              </div>
            </div>
            <div className="composer-toolbar">
              <MentionPicker
                members={members}
                currentUserId={currentUserId}
                selectedUserIds={mentionedUserIds}
                disabled={sending}
                onChange={onMentionedUserIdsChange}
              />
              <p className="composer-footnote">
                <span>Enter to send · Shift+Enter for a new line</span>
              </p>
            </div>
          </form>
        </>
      ) : (
        <div className="empty-state full-height">
          <span className="empty-mark" aria-hidden="true">
            <AppIcon name="message" />
          </span>
          <h2>Select a conversation</h2>
          <p>Choose a direct message, group or channel.</p>
        </div>
      )}
    </section>
  );
}
