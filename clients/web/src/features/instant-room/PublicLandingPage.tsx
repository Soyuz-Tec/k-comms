import type { ReactNode } from "react";

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
    </div>
  );
}
