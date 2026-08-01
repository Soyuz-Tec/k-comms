import { AppIcon } from "../../components/AppIcon";
import { PublicLandingBrandMark } from "./PublicLandingBrand";
import "./PublicLandingPreview.css";

export function ProductPreview() {
  return (
    <div
      className="public-landing-preview"
      role="img"
      aria-label="K-Comms desktop workspace with a mobile conversation alongside it"
    >
      <div className="public-landing-preview-glow" aria-hidden="true" />
      <div className="public-landing-desktop" aria-hidden="true">
        <div className="preview-window-bar">
          <div className="preview-window-brand">
            <PublicLandingBrandMark />
            <strong>K-Comms</strong>
          </div>
          <span>Product team</span>
          <AppIcon name="search" />
        </div>
        <div className="preview-workspace">
          <aside className="preview-rail">
            <span className="selected"><AppIcon name="messages" /> Messages</span>
            <span><AppIcon name="phone" /> Calls</span>
            <span><AppIcon name="file" /> Files</span>
            <span><AppIcon name="whiteboard" /> Whiteboard</span>
          </aside>
          <div className="preview-conversation">
            <div className="preview-conversation-heading">
              <div><span>Launch room</span><small>5 people here</small></div>
              <div><AppIcon name="phone" /><AppIcon name="video" /></div>
            </div>
            <div className="preview-message">
              <span className="preview-avatar">AM</span>
              <p><strong>Alex</strong><span>The updated flow is on the whiteboard.</span></p>
            </div>
            <div className="preview-whiteboard-card">
              <span><AppIcon name="whiteboard" /> Launch flow</span>
              <div><i /><i /><i /></div>
            </div>
            <div className="preview-message own">
              <span className="preview-avatar">YO</span>
              <p><strong>You</strong><span>Perfect. I’ll start the room.</span></p>
            </div>
            <div className="preview-composer">
              <AppIcon name="paperclip" />
              <span>Message launch room</span>
              <AppIcon name="send" />
            </div>
          </div>
          <aside className="preview-call-panel">
            <div className="preview-video primary"><span>AK</span><small>Aki</small></div>
            <div className="preview-video secondary"><span>MR</span><small>Mira</small></div>
            <div className="preview-call-controls">
              <AppIcon name="mic" /><AppIcon name="video" /><AppIcon name="screenShare" />
            </div>
          </aside>
        </div>
      </div>
      <div className="public-landing-phone" aria-hidden="true">
        <div className="preview-phone-top"><span>9:41</span><i /></div>
        <div className="preview-phone-heading">
          <AppIcon name="chevronLeft" />
          <span><strong>Launch room</strong><small>5 people here</small></span>
          <AppIcon name="video" />
        </div>
        <div className="preview-phone-messages">
          <p><span>Let’s walk through it together.</span><small>Alex · 9:38</small></p>
          <p className="own"><span>Joining from my phone.</span><small>9:39</small></p>
          <div><AppIcon name="paperclip" /><span>Message</span><AppIcon name="send" /></div>
        </div>
        <nav aria-label="Mobile preview navigation">
          <span className="selected"><AppIcon name="messages" /></span>
          <span><AppIcon name="phone" /></span>
          <span><AppIcon name="whiteboard" /></span>
          <span><AppIcon name="user" /></span>
        </nav>
      </div>
    </div>
  );
}
