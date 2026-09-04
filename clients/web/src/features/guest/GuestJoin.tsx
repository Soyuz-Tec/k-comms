import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import { Link } from "react-router";
import type { ApiClient, GuestApiClient } from "../../api";
import { ApiError } from "../../api";
import { browserName, formatDateTime } from "../../lib/format";
import type {
  GuestLinkPreview,
  GuestSession,
  InstantRoomPreview,
  InstantRoomResult,
  Session
} from "../../types";
import {
  guestLinkError,
  isRetryableGuestLinkFailure,
  joinInstantRoomWithReplayRecovery,
  setGuestRetryDeadline,
  withoutGuestConversion
} from "./guestAccessPolicy";

export function GuestJoin({
  api,
  accountApi,
  accountSession,
  accountActionsAllowed,
  mediaActionsAllowed,
  token,
  accessEnded,
  onJoined,
  onAccountJoined
}: {
  api: GuestApiClient;
  accountApi: ApiClient;
  accountSession: Session | null;
  accountActionsAllowed: boolean;
  mediaActionsAllowed: boolean;
  token: string | null;
  accessEnded: boolean;
  onJoined: (session: GuestSession) => void;
  onAccountJoined: (result: InstantRoomResult) => void;
}) {
  const [preview, setPreview] = useState<
    GuestLinkPreview | InstantRoomPreview | null
  >(null);
  const [instantRoom, setInstantRoom] = useState(false);
  const [loading, setLoading] = useState(Boolean(token));
  const [joining, setJoining] = useState(false);
  const [joinAsGuest, setJoinAsGuest] = useState(false);
  const [error, setError] = useState("");
  const [previewRetryable, setPreviewRetryable] = useState(false);
  const [previewRetry, setPreviewRetry] = useState(0);
  const [retryAt, setRetryAt] = useState<number | null>(null);
  const [clock, setClock] = useState(Date.now());

  useEffect(() => {
    if (!token) return;
    let current = true;
    setLoading(true);
    setError("");
    setPreviewRetryable(false);
    void accountApi.previewInstantRoom(token).then((result) => {
      if (current) {
        setInstantRoom(true);
        setPreview(result);
        setRetryAt(null);
      }
    }).catch(async (reason: unknown) => {
      const legacyGuestLinkCandidate =
        reason instanceof ApiError &&
        (reason.status === 404 ||
          (reason.status === 503 && reason.code === "instant_rooms_unavailable"));

      if (!legacyGuestLinkCandidate) throw reason;
      const result = await api.previewGuestLink(token);
      if (current) {
        setInstantRoom(false);
        setPreview(result);
        setRetryAt(null);
      }
    }).catch((reason: unknown) => {
      if (current) {
        setError(guestLinkError(reason));
        setPreviewRetryable(isRetryableGuestLinkFailure(reason));
        setGuestRetryDeadline(reason, setRetryAt, setClock);
      }
    }).finally(() => {
      if (current) setLoading(false);
    });
    return () => {
      current = false;
    };
  }, [accountApi, api, previewRetry, token]);

  useEffect(() => {
    if (!retryAt) return;
    const timer = window.setInterval(() => {
      const now = Date.now();
      setClock(now);
      if (now >= retryAt) setRetryAt(null);
    }, 1_000);
    return () => window.clearInterval(timer);
  }, [retryAt]);

  const retrySeconds = retryAt
    ? Math.max(0, Math.ceil((retryAt - clock) / 1_000))
    : 0;
  const retryBlocked = retrySeconds > 0;

  const accountCanJoin = Boolean(accountSession && instantRoom);
  const legacyConversionOffered =
    preview !== null &&
    "conversion_enabled" in preview &&
    preview.conversion_enabled === true;

  async function joinWithAccount() {
    if (!token || !accountSession || retryBlocked) return;
    setJoining(true);
    setError("");
    try {
      const result = await joinInstantRoomWithReplayRecovery(
        token,
        "account",
        (idempotencyKey) =>
          accountApi.joinInstantRoom({ token }, idempotencyKey)
      );
      if (result.guest_session) {
        onJoined(withoutGuestConversion(result.guest_session));
        return;
      }
      onAccountJoined(result);
    } catch (reason: unknown) {
      setError(guestLinkError(reason));
      setGuestRetryDeadline(reason, setRetryAt, setClock);
    } finally {
      setJoining(false);
    }
  }

  async function join(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!token) return;
    const values = new FormData(event.currentTarget);
    const displayName = String(values.get("display_name") || "").trim();
    if (!displayName || retryBlocked) return;

    setJoining(true);
    setError("");
    try {
      const input = {
        token,
        display_name: displayName,
        device: { name: browserName(), platform: "web" as const }
      };
      onJoined(
        instantRoom
          ? await joinInstantRoomWithReplayRecovery(
              token,
              "guest",
              (idempotencyKey) =>
                api.joinInstantRoom(input, idempotencyKey)
            )
          : await api.joinGuest(input)
      );
    } catch (reason: unknown) {
      setError(guestLinkError(reason));
      setGuestRetryDeadline(reason, setRetryAt, setClock);
    } finally {
      setJoining(false);
    }
  }

  return (
    <main className="guest-entry" id="main-content">
      <section className="guest-entry-card" aria-labelledby="guest-entry-title">
        {(!accountActionsAllowed || !mediaActionsAllowed) && (
          <div className="transport-warning" role="alert">
            <strong>Secure account and media actions are unavailable.</strong>
            <span>
              Use non-sensitive content only. Open K-Comms over trusted HTTPS
              before using account actions, microphone, camera, or screen
              sharing.
            </span>
          </div>
        )}
        {loading ? (
          <div className="guest-entry-loading" role="status">
            <span className="spinner" aria-hidden="true" />
            <h1 id="guest-entry-title">Checking your invite link…</h1>
          </div>
        ) : preview ? (
          <>
            <span className="guest-badge">Guest access · One room</span>
            <h1 id="guest-entry-title">{preview.room_title}</h1>
            <p>
              {legacyConversionOffered
                ? "Join this room now. No account is required. Optional account creation needs the separate one-time code from the host."
                : "Join this room now without creating an account. This link provides temporary communication access only."}
            </p>
            {accountCanJoin && !joinAsGuest ? (
              <div className="guest-join-form">
                <button
                  className="button primary full"
                  type="button"
                  disabled={joining || retryBlocked}
                  onClick={() => void joinWithAccount()}
                >
                  {retryBlocked
                    ? `Try again in ${retrySeconds}s`
                    : joining
                    ? "Joining room…"
                    : `Join as ${accountSession?.user.display_name}`}
                </button>
                <button
                  className="button ghost full"
                  type="button"
                  disabled={joining || retryBlocked}
                  onClick={() => setJoinAsGuest(true)}
                >
                  Use a guest name instead
                </button>
              </div>
            ) : (
            <form className="guest-join-form" onSubmit={(event) => void join(event)}>
              <label className="field">
                Your display name
                <input
                  name="display_name"
                  type="text"
                  minLength={1}
                  maxLength={120}
                  autoComplete="name"
                  autoFocus
                  required
                  placeholder="How people should see you"
                />
              </label>
              <button
                className="button primary full"
                type="submit"
                disabled={joining || retryBlocked}
              >
                {retryBlocked
                  ? `Try again in ${retrySeconds}s`
                  : joining
                    ? "Joining room…"
                    : "Join conversation"}
              </button>
            </form>
            )}
            <small className="guest-expiry">
              {preview.expires_at
                ? `This invitation expires ${formatDateTime(preview.expires_at)}.`
                : instantRoom
                  ? "This room stays active while someone is connected. Its idle countdown starts after the last person leaves."
                  : "The host controls when this invitation ends."}
            </small>
          </>
        ) : (
          <>
            <span className="guest-badge neutral">Guest link</span>
            <h1 id="guest-entry-title">
              {token
                ? previewRetryable
                  ? "We could not check this guest link"
                  : "This guest link is unavailable"
                : accessEnded
                  ? "Guest access has ended"
                  : "Open a K-Comms guest link"}
            </h1>
            <p>
              {token
                ? previewRetryable
                  ? "Your invite link is unchanged. Retry it here when K-Comms is available."
                  : "It may have expired, reached its guest limit or been revoked. Ask the room host for a new link."
                : accessEnded
                  ? "This guest session expired or was revoked. Ask the room host for a new link."
                  : "Scan the room QR code or open the unique link shared by its host."}
            </p>
            <div className="guest-entry-actions">
              {token && previewRetryable && (
                <button
                  className="button primary full"
                  type="button"
                  disabled={retryBlocked}
                  onClick={() => {
                    if (retryBlocked) return;
                    setRetryAt(null);
                    setPreviewRetry((attempt) => attempt + 1);
                  }}
                >
                  {retryBlocked
                    ? `Try again in ${retrySeconds}s`
                    : "Retry invite link"}
                </button>
              )}
              {(!token || !previewRetryable) && (
                <Link className="button primary full" to="/">
                  Start new room
                </Link>
              )}
              <Link
                className="button ghost full"
                to="/sign-in"
              >
                Sign in to a workspace
              </Link>
            </div>
          </>
        )}
        {error && <p className="form-error" role="alert">{error}</p>}
      </section>
    </main>
  );
}
