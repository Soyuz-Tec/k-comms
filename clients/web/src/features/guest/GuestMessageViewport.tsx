import type {
  FormEvent,
  RefObject
} from "react";
import { AppIcon } from "../../components/AppIcon";
import { formatTime, initials } from "../../lib/format";
import type { Message } from "../../types";

export interface GuestMessageSender {
  displayName: string;
  identifier: string;
  guest: boolean;
}

export function GuestMessageViewport({
  autoFocus,
  composer,
  composerRef,
  conversationTitle,
  currentUserId,
  identityLabel,
  isNearBottom,
  loadError,
  loading,
  messages,
  messageScrollRef,
  mobile,
  newMessageCount,
  onComposerChange,
  onJumpToLatest,
  onRetryLoad,
  onScroll,
  onSubmit,
  resolveSender,
  sending
}: {
  autoFocus: boolean;
  composer: string;
  composerRef: RefObject<HTMLTextAreaElement | null>;
  conversationTitle: string;
  currentUserId: string;
  identityLabel: "Guest" | "Host" | "Member";
  isNearBottom: boolean;
  loadError: string;
  loading: boolean;
  messages: Message[];
  messageScrollRef: RefObject<HTMLDivElement | null>;
  mobile: boolean;
  newMessageCount: number;
  onComposerChange: (value: string) => void;
  onJumpToLatest: () => void;
  onRetryLoad: () => void;
  onScroll: () => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
  resolveSender: (message: Message) => GuestMessageSender;
  sending: boolean;
}) {
  return (
    <section className="guest-room" aria-label={conversationTitle}>
      <div
        ref={messageScrollRef}
        className="guest-message-scroll"
        role="region"
        aria-label="Message history"
        aria-busy={loading}
        tabIndex={0}
        onScroll={onScroll}
      >
        {loading ? (
          <div className="inline-loading" role="status">
            <span className="spinner" aria-hidden="true" />
            Loading conversation…
          </div>
        ) : loadError ? (
          <div className="empty-state guest-load-error" role="alert">
            <span className="empty-mark" aria-hidden="true">
              <AppIcon name="triangleAlert" />
            </span>
            <h2>Could not load this conversation</h2>
            <p>{loadError}</p>
            <button
              className="button primary"
              type="button"
              onClick={onRetryLoad}
            >
              <AppIcon name="refresh" />
              Retry conversation
            </button>
          </div>
        ) : messages.length === 0 ? (
          <div className="empty-state guest-message-empty">
            <h2>No messages yet</h2>
            <p>
              {identityLabel === "Guest"
                ? "You joined as a guest. "
                : "Your room is ready. "}
              Send a message when you’re ready.
            </p>
          </div>
        ) : (
          <ol className="guest-message-list">
            {messages.map((message) => {
              const sender = resolveSender(message);
              return (
                <li
                  key={message.id}
                  className={
                    message.sender_user_id === currentUserId ? "mine" : ""
                  }
                >
                  <span className="avatar" aria-hidden="true">
                    {initials(sender.displayName)}
                  </span>
                  <div>
                    <div className="guest-message-meta">
                      <strong>
                        {sender.identifier}
                        {message.sender_user_id === currentUserId && " (you)"}
                      </strong>
                      {sender.guest && (
                        <span className="guest-badge compact">Guest</span>
                      )}
                      <time dateTime={message.inserted_at}>
                        {formatTime(message.inserted_at)}
                      </time>
                    </div>
                    <p>{message.body}</p>
                  </div>
                </li>
              );
            })}
          </ol>
        )}
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
      {!isNearBottom && newMessageCount > 0 && (
        <div className="guest-new-message-jump">
          <button
            className="button primary compact"
            type="button"
            onClick={onJumpToLatest}
          >
            <AppIcon name="arrowDown" />
            {newMessageCount} new{" "}
            {newMessageCount === 1 ? "message" : "messages"} · Jump to latest
          </button>
        </div>
      )}
      <form
        className="guest-composer"
        onSubmit={(event) => onSubmit(event)}
      >
        <div className="composer-shell">
          <label className="sr-only" htmlFor="guest-message-composer">
            Message
          </label>
          <textarea
            ref={composerRef}
            id="guest-message-composer"
            rows={mobile ? 1 : 2}
            maxLength={65_535}
            value={composer}
            readOnly={sending || loading || Boolean(loadError)}
            aria-busy={sending}
            aria-disabled={loading || Boolean(loadError)}
            autoFocus={autoFocus}
            placeholder={
              mobile ? "Write a message" : `Message ${conversationTitle}`
            }
            onChange={(event) => onComposerChange(event.target.value)}
            onKeyDown={(event) => {
              if (
                event.key === "Enter" &&
                !event.shiftKey &&
                !event.nativeEvent.isComposing
              ) {
                event.preventDefault();
                event.currentTarget.form?.requestSubmit();
              }
            }}
          />
          <div className="composer-inline-actions">
            <button
              className="composer-icon-button composer-send send-button"
              type="submit"
              aria-busy={sending}
              aria-label={sending ? "Sending message" : "Send"}
              disabled={
                sending || loading || Boolean(loadError) || !composer.trim()
              }
            >
              <AppIcon
                name={sending ? "loader" : "send"}
                className={sending ? "spin" : ""}
              />
            </button>
          </div>
        </div>
      </form>
    </section>
  );
}
