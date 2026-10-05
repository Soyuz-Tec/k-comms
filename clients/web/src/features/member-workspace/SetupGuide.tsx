import { Link } from "react-router";
import { useMemberWorkspace } from "./useMemberWorkspace";
import "./memberWorkspace.css";

type WorkspaceController = ReturnType<typeof useMemberWorkspace>;

export function SetupGuide({ controller, settings = false }: { controller: WorkspaceController; settings?: boolean }) {
  const { data, loading, busy, error, denied, refresh, onboarding, pendingOnboarding } = controller;
  if (denied) return <p role="alert">Your setup progress is unavailable. Sign in again to continue.</p>;
  if (!data) return <div className="member-setup-guide">
    {loading ? <p role="status">Loading setup progress…</p> : <>
      <p role="alert">{error || "Setup progress could not be synchronized."}</p>
      <button type="button" onClick={() => void refresh()}>Retry setup progress</button>
    </>}
  </div>;
  if (data.onboarding.dismissed_at && !settings && !error) return null;
  const profileReviewed = Boolean(data.onboarding.profile_reviewed_at);
  return <section className="member-setup-guide" aria-label="Setup guide">
    {error && <div className="inline-notice error" role="alert">
      <p>{error}</p>
      {pendingOnboarding && <button type="button" disabled={busy} onClick={() => void onboarding(pendingOnboarding)}>Retry setup change</button>}
    </div>}
    {data.onboarding.dismissed_at ? <>
      <p>Setup is hidden across your signed-in browsers.</p>
      <button type="button" disabled={busy} onClick={() => void onboarding("resume")}>{busy ? "Synchronizing…" : "Resume setup"}</button>
    </> : <details open={settings || undefined}>
      <summary>Setup guide <span>{profileReviewed ? "Profile reviewed" : "Review your profile"}</span></summary>
      <ul>
        <li><Link to="/app/you?section=profile">Review profile</Link><span>{profileReviewed ? "Saved and reviewed" : "Save your profile to record review"}</span></li>
        <li><Link to="/app/directory">Find teammates</Link><span>{data.onboarding.has_teammates ? "Teammates available" : "No active teammates yet"}</span></li>
        <li><Link to="/app/you?section=security">Review sign-in devices</Link><span>{data.onboarding.active_devices} active device{data.onboarding.active_devices === 1 ? "" : "s"}</span></li>
        <li><Link to="/app/you?section=audio-video">Check audio &amp; video</Link><span>Tests and media permissions apply to this browser.</span></li>
        <li><Link to="/app/you?section=notifications">Set up notifications</Link><span>Browser notification permission requires your explicit choice.</span></li>
      </ul>
      <div className="member-workspace-actions">
        <button type="button" disabled={busy} onClick={() => void onboarding("dismiss")}>Hide for now</button>
        {settings && <button type="button" disabled={busy} onClick={() => void onboarding("reset")}>Reset setup review</button>}
      </div>
    </details>}
  </section>;
}

export function AccountSetupGuide() {
  const controller = useMemberWorkspace();
  return <SetupGuide key={controller.identity} controller={controller} settings />;
}
