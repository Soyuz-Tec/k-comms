import type { ReactNode } from "react";
import { Link } from "react-router";
import { AppIcon } from "../../components/AppIcon";
import { PublicLandingBrandMark } from "./PublicLandingBrand";

type PublicLandingPageProps = {
  workspace: ReactNode;
  signedIn: boolean;
};

export function PublicLandingPage({
  workspace,
  signedIn
}: PublicLandingPageProps) {
  return (
    <div className="public-landing public-workspace-landing">
      <a className="skip-link" href="#main-content">
        Skip to main content
      </a>

      <header className="public-workspace-header">
        <Link className="public-landing-brand" to="/" aria-label="K-Comms home">
          <PublicLandingBrandMark />
          <span>K-Comms</span>
        </Link>
        <span className="public-workspace-availability">
          <span aria-hidden="true" />
          Instant collaboration
        </span>
        <Link
          className="button public-landing-account"
          to={signedIn ? "/app/" : "/sign-in"}
        >
          <AppIcon name={signedIn ? "arrowUpRight" : "logIn"} />
          {signedIn ? "Open workspace" : "Sign in"}
        </Link>
      </header>

      <main className="public-workspace-main" id="main-content">
        {workspace}
      </main>

      <footer className="public-workspace-footer">
        <span><AppIcon name="check" /> Conversation-scoped access</span>
        <span><AppIcon name="clock" /> Rooms expire after inactivity</span>
        <span><AppIcon name="lock" /> Secure media requires trusted HTTPS</span>
      </footer>
    </div>
  );
}
