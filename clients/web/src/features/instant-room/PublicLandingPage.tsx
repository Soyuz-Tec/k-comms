import type { MouseEvent, ReactNode } from "react";
import { Link } from "react-router";
import { AppIcon, type AppIconName } from "../../components/AppIcon";
import { PublicLandingBrandMark } from "./PublicLandingBrand";
import { ProductPreview } from "./PublicLandingProductPreview";

type PublicLandingPageProps = {
  launcher: ReactNode;
  signedIn: boolean;
};

const capabilities: Array<{
  icon: AppIconName;
  title: string;
  description: string;
}> = [
  {
    icon: "messages",
    title: "Messaging that stays organized",
    description:
      "Move between direct messages and shared rooms without losing the thread."
  },
  {
    icon: "video",
    title: "Calls built into the work",
    description:
      "Start audio or video calls, invite guests, and share your screen from one place."
  },
  {
    icon: "whiteboard",
    title: "A canvas everyone can shape",
    description:
      "Sketch ideas together on an Excalidraw-powered whiteboard beside the conversation."
  },
  {
    icon: "paperclip",
    title: "Files where people need them",
    description:
      "Share managed attachments in context instead of sending people to another tool."
  }
];

export function PublicLandingPage({
  launcher,
  signedIn
}: PublicLandingPageProps) {
  return (
    <div className="public-landing">
      <a className="skip-link" href="#main-content">
        Skip to main content
      </a>

      <header className="public-landing-header">
        <Link className="public-landing-brand" to="/" aria-label="K-Comms home">
          <PublicLandingBrandMark />
          <span>K-Comms</span>
        </Link>
        <nav className="public-landing-nav" aria-label="Product navigation">
          <a href="#product">Product</a>
          <a href="#apps">Apps</a>
          <a href="#trust">Trust</a>
        </nav>
        <Link
          className="button public-landing-account"
          to={signedIn ? "/app/" : "/sign-in"}
        >
          <AppIcon name={signedIn ? "arrowUpRight" : "logIn"} />
          {signedIn ? "Open workspace" : "Sign in"}
        </Link>
      </header>

      <main id="main-content">
        <section className="public-landing-hero" aria-labelledby="public-landing-title">
          <div className="public-landing-hero-copy">
            <span className="public-landing-status">
              <span aria-hidden="true" />
              Web app available now
            </span>
            <h1 id="public-landing-title" data-route-focus>
              One place to talk,
              <br />meet, and make.
            </h1>
            <p>
              K-Comms brings messages, calls, screen sharing, files, and a
              shared whiteboard into one focused workspace—on desktop or phone.
            </p>
            <div className="public-landing-hero-actions">
              <a
                className="button primary"
                href="#start-room"
                onClick={focusRoomLauncher}
              >
                Start a room
                <AppIcon name="arrowDown" />
              </a>
              <Link className="button ghost" to={signedIn ? "/app/" : "/sign-in"}>
                {signedIn ? "Go to your workspace" : "Use your workspace"}
              </Link>
            </div>
            <ul className="public-landing-hero-notes" aria-label="Instant room benefits">
              <li><AppIcon name="check" /> No account needed for instant rooms</li>
              <li><AppIcon name="check" /> One link works across devices</li>
            </ul>
          </div>

          <ProductPreview />
        </section>

        <section
          className="public-landing-capabilities"
          id="product"
          aria-labelledby="capabilities-title"
        >
          <div className="public-landing-section-heading">
            <span className="eyebrow">A calmer way to collaborate</span>
            <h2 id="capabilities-title">The conversation is the workspace.</h2>
            <p>
              Keep the people, decisions, media, and working material together
              from the first message to the finished idea.
            </p>
          </div>
          <div className="public-landing-capability-grid">
            {capabilities.map((capability) => (
              <article key={capability.title}>
                <span className="public-landing-capability-icon" aria-hidden="true">
                  <AppIcon name={capability.icon} />
                </span>
                <h3>{capability.title}</h3>
                <p>{capability.description}</p>
              </article>
            ))}
          </div>
        </section>

        <section
          className="public-landing-apps"
          id="apps"
          aria-labelledby="apps-title"
        >
          <div className="public-landing-section-heading compact">
            <span className="eyebrow">Every screen, one workspace</span>
            <h2 id="apps-title">Use K-Comms where the work happens.</h2>
            <p>
              The responsive web app is ready today and can be installed as a
              PWA in supported browsers. Native packages remain on the roadmap.
            </p>
          </div>
          <div className="public-landing-app-grid">
            <article>
              <div className="public-landing-app-icon desktop" aria-hidden="true">
                <AppIcon name="screenShare" />
              </div>
              <div>
                <span className="public-landing-availability available">Available now</span>
                <h3>Desktop web app</h3>
                <p>Full workspace, calls, screen sharing, files, and whiteboards.</p>
              </div>
            </article>
            <article>
              <div className="public-landing-app-icon mobile" aria-hidden="true">
                <AppIcon name="message" />
              </div>
              <div>
                <span className="public-landing-availability available">Available now</span>
                <h3>Mobile web app</h3>
                <p>Responsive conversations and room controls that fit smaller screens.</p>
              </div>
            </article>
            <article>
              <div className="public-landing-app-icon" aria-hidden="true">
                <AppIcon name="download" />
              </div>
              <div>
                <span className="public-landing-availability">Roadmap</span>
                <h3>Native app packages</h3>
                <p>Dedicated mobile and desktop packages are planned, not released yet.</p>
              </div>
            </article>
          </div>
        </section>

        <section
          className="public-landing-room"
          id="start-room"
          aria-labelledby="room-section-title"
        >
          <div className="public-landing-room-copy">
            <span className="eyebrow light">Start together in seconds</span>
            <h2 id="room-section-title">A useful meeting should not begin with setup.</h2>
            <p>
              Add your name, give the room a title if you want one, and share a
              single link. Your guests can join from their browser.
            </p>
            <ul>
              <li><AppIcon name="users" /> Guest-friendly entry</li>
              <li><AppIcon name="video" /> Audio and video when HTTPS is trusted</li>
              <li><AppIcon name="whiteboard" /> Conversation-linked whiteboards</li>
            </ul>
          </div>
          <div className="public-landing-launcher">
            {launcher}
          </div>
        </section>

        <section
          className="public-landing-trust"
          id="trust"
          aria-labelledby="trust-title"
        >
          <div>
            <span className="public-landing-trust-icon" aria-hidden="true">
              <AppIcon name="check" />
            </span>
            <span className="eyebrow">Designed for real work</span>
            <h2 id="trust-title">Clear boundaries. Honest controls.</h2>
          </div>
          <div className="public-landing-trust-points">
            <article>
              <h3>Workspace-aware access</h3>
              <p>Member activity stays scoped to the workspace and conversation.</p>
            </article>
            <article>
              <h3>Transport-aware protection</h3>
              <p>
                Account and media controls stay unavailable when K-Comms cannot
                verify a trusted HTTPS connection.
              </p>
            </article>
            <article>
              <h3>Durable collaboration</h3>
              <p>Messages and shared work remain connected when people return.</p>
            </article>
          </div>
        </section>
      </main>

      <footer className="public-landing-footer">
        <Link className="public-landing-brand" to="/" aria-label="K-Comms home">
          <PublicLandingBrandMark />
          <span>K-Comms</span>
        </Link>
        <p>Messaging, meetings, and shared work—together.</p>
        <div>
          <a href="#product">Product</a>
          <a href="#apps">Apps</a>
          <Link to="/sign-in">Sign in</Link>
        </div>
      </footer>
    </div>
  );
}

function focusRoomLauncher(event: MouseEvent<HTMLAnchorElement>) {
  event.preventDefault();
  window.history.replaceState(
    window.history.state,
    "",
    `${window.location.pathname}${window.location.search}#start-room`
  );
  window.requestAnimationFrame(() => {
    const heading = document.getElementById("instant-room-start-title");
    if (!heading) return;
    heading.setAttribute("tabindex", "-1");
    heading.focus({ preventScroll: true });
    heading.scrollIntoView({ block: "center" });
    heading.addEventListener(
      "blur",
      () => heading.removeAttribute("tabindex"),
      { once: true }
    );
  });
}
