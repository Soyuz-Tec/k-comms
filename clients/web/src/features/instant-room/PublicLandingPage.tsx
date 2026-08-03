import type { ReactNode } from "react";
import { AppIcon } from "../../components/AppIcon";

type PublicLandingPageProps = {
  workspace: ReactNode;
};

export function PublicLandingPage({ workspace }: PublicLandingPageProps) {
  return (
    <div className="public-landing public-workspace-landing">
      <a className="skip-link" href="#main-content">
        Skip to main content
      </a>

      <main className="public-workspace-main" id="main-content">
        {workspace}
      </main>

      <footer
        className="public-workspace-footer"
        aria-label="Draft privacy and room lifecycle"
      >
        <span><AppIcon name="check" /> Local drafts expire after 24 hours</span>
        <span><AppIcon name="clock" /> Shared rooms expire after inactivity</span>
        <span><AppIcon name="lock" /> Calls request permission inside the room</span>
      </footer>
    </div>
  );
}
