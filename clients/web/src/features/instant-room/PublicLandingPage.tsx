import type { ReactNode } from "react";
import { Link } from "react-router";
import { AppIcon } from "../../components/AppIcon";
import { PublicLandingBrandMark } from "./PublicLandingBrand";

type PublicLandingPageProps = {
  launcher: ReactNode;
  signedIn: boolean;
};

export function PublicLandingPage({
  launcher,
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
        <section className="public-workspace-welcome" aria-labelledby="public-workspace-title">
          <div className="public-workspace-copy">
            <span className="eyebrow light">No account required</span>
            <h1 id="public-workspace-title" data-route-focus>
              Message. Draw. Share.
            </h1>
            <p>
              Open one working room with live messaging and an Excalidraw canvas,
              then invite anyone with a secure link or QR code.
            </p>
            <ul aria-label="Workspace capabilities">
              <li><AppIcon name="messages" /> Live conversation</li>
              <li><AppIcon name="whiteboard" /> Shared drawing canvas</li>
              <li><AppIcon name="qrCode" /> QR and invitation link</li>
              <li><AppIcon name="video" /> Audio, video, and screen sharing</li>
            </ul>
          </div>

          <div className="public-workspace-launcher" id="start-room">
            {launcher}
          </div>
        </section>

        <section className="public-workspace-preview" aria-label="K-Comms workspace preview">
          <div className="public-workspace-preview-header">
            <div>
              <span className="public-workspace-preview-dot" aria-hidden="true" />
              <strong>Shared workspace</strong>
            </div>
            <span>Ready when you are</span>
          </div>
          <div className="public-workspace-preview-body">
            <div className="public-workspace-preview-canvas">
              <div className="public-workspace-preview-toolbar" aria-hidden="true">
                <AppIcon name="mousePointer" />
                <AppIcon name="square" />
                <AppIcon name="message" />
                <AppIcon name="pencil" />
              </div>
              <div className="public-workspace-preview-note one">
                <strong>Ideas stay visible</strong>
                <span>Sketch the plan together</span>
              </div>
              <div className="public-workspace-preview-arrow" aria-hidden="true">→</div>
              <div className="public-workspace-preview-note two">
                <strong>Decisions stay connected</strong>
                <span>Keep the conversation beside the canvas</span>
              </div>
            </div>
            <aside className="public-workspace-preview-chat">
              <div><span>AY</span><p><strong>Alara</strong>Let’s map the launch flow.</p></div>
              <div className="mine"><p><strong>You</strong>I’ll share the room.</p></div>
              <div className="public-workspace-preview-composer">
                <span>Message the room</span><AppIcon name="send" />
              </div>
            </aside>
          </div>
        </section>
      </main>

      <footer className="public-workspace-footer">
        <span><AppIcon name="check" /> Conversation-scoped access</span>
        <span><AppIcon name="clock" /> Rooms expire after inactivity</span>
        <span><AppIcon name="lock" /> Secure media requires trusted HTTPS</span>
      </footer>
    </div>
  );
}
