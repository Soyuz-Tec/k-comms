import { useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "react-router";
import { useSession } from "../../app/session";
import { safeMemberReturnTarget } from "../../app/authNavigation";
import { errorText } from "../../lib/format";

export function OidcCallback() {
  const { api, setSession } = useSession();
  const navigate = useNavigate();
  const started = useRef(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const params = new URLSearchParams(window.location.search);
    const code = params.get("code"); const state = params.get("state");
    // Remove one-use credentials before rendering, telemetry, or navigation.
    window.history.replaceState(window.history.state, "", window.location.pathname);
    let linking: boolean;
    try {
      linking = sessionStorage.getItem("kcomms:oidc-link") === "1";
      sessionStorage.removeItem("kcomms:oidc-link");
    } catch {
      setError("Browser storage is unavailable. Allow storage for this site and restart corporate sign in.");
      return;
    }
    if (!code || !state) { setError("Corporate sign in did not return a valid authorization code."); return; }
    const work = linking ? api.completeOidcLink(code, state) : api.completeOidc(code, state);
    work.then((result) => {
      if ("session" in result) setSession(result.session);
      navigate(safeMemberReturnTarget(result.return_to) || "/app/", { replace: true });
    }).catch((reason: unknown) => setError(errorText(reason)));
  }, [api, navigate, setSession]);
  return <main><h1>Corporate sign in</h1>{error ? <><p role="alert">{error}</p><Link to="/sign-in">Return to sign in</Link></> : <p role="status">Verifying your corporate identity…</p>}</main>;
}
