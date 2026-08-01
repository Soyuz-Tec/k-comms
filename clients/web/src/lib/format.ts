import { ApiError } from "../api";
import type { Conversation } from "../types";

export function conversationTitle(conversation: Conversation): string {
  if (conversation.kind === "direct") {
    return conversation.counterpart_display_name?.trim() || "Direct message";
  }

  return (
    conversation.title?.trim() ||
    "Untitled conversation"
  );
}

export function initials(value: string): string {
  return (
    value
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((part) => part[0]?.toUpperCase())
      .join("") || "?"
  );
}

export function formatTime(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? ""
    : new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(date);
}

export function formatDateTime(value?: string | null): string {
  if (!value) return "Not recorded";
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? "Not recorded"
    : new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date);
}

/**
 * Stable key for "which calendar day is this timestamp on", in the reader's
 * own timezone. Comparing these tells the message list where a day boundary
 * falls; comparing raw timestamps would put the boundary at UTC midnight,
 * which is the wrong place for everyone outside UTC.
 */
export function dayKey(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
}

/** Human day label for a divider: "Today", "Yesterday", or a full date. */
export function formatDayLabel(value: string, now: Date = new Date()): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const today = dayKey(now.toISOString());
  const yesterday = new Date(now);
  yesterday.setDate(yesterday.getDate() - 1);
  const key = dayKey(value);
  if (key === today) return "Today";
  if (key === dayKey(yesterday.toISOString())) return "Yesterday";
  const sameYear = date.getFullYear() === now.getFullYear();
  return new Intl.DateTimeFormat(undefined, sameYear
    ? { weekday: "long", day: "numeric", month: "long" }
    : { day: "numeric", month: "long", year: "numeric" }).format(date);
}

export function formatBytes(value: number): string {
  if (value < 1_000) return `${value} B`;
  if (value < 1_000_000) return `${(value / 1_000).toFixed(1)} KB`;
  return `${(value / 1_000_000).toFixed(1)} MB`;
}

export function clientMessageId(): string {
  return globalThis.crypto.randomUUID
    ? globalThis.crypto.randomUUID()
    : `web-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

export function browserName(): string {
  return `Web · ${navigator.platform || "browser"}`;
}

export function stringValue(form: FormData, key: string): string {
  return String(form.get(key) || "").trim();
}

export function errorText(reason: unknown): string {
  if (reason instanceof ApiError) return reason.message;
  if (reason instanceof Error) return reason.message;
  return "Something went wrong. Please try again.";
}
