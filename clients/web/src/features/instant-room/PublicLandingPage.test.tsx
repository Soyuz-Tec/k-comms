import { render, screen, within } from "@testing-library/react";
import { BrowserRouter } from "react-router";
import { describe, expect, it } from "vitest";
import { PublicLandingPage } from "./PublicLandingPage";

function renderLandingPage(signedIn = false) {
  return render(
    <BrowserRouter>
      <PublicLandingPage
        signedIn={signedIn}
        workspace={
          <section aria-label="Working workspace">
            <h1>Message. Draw. Share.</h1>
            <div aria-label="Private drawing canvas">Canvas</div>
            <div aria-label="Workspace messages">Messages</div>
          </section>
        }
      />
    </BrowserRouter>
  );
}

describe("PublicLandingPage", () => {
  it("opens with the working collaboration workspace", () => {
    renderLandingPage();

    expect(
      screen.getByRole("heading", {
        name: "Message. Draw. Share."
      })
    ).toBeVisible();
    expect(screen.getByText("Instant collaboration")).toBeVisible();
    expect(screen.getByRole("region", { name: "Working workspace" })).toBeVisible();
    expect(screen.getByLabelText("Private drawing canvas")).toBeVisible();
    expect(screen.getByLabelText("Workspace messages")).toBeVisible();
  });

  it("shows the message-and-canvas workspace before room creation", () => {
    renderLandingPage();

    expect(screen.getByLabelText("Private drawing canvas")).toHaveTextContent("Canvas");
    expect(screen.getByLabelText("Workspace messages")).toHaveTextContent("Messages");
    expect(screen.getByText("Conversation-scoped access")).toBeVisible();
  });

  it("routes signed-out visitors to sign in and members to their workspace", () => {
    const view = renderLandingPage();
    const signedOutHeader = screen.getByRole("banner");
    expect(within(signedOutHeader).getByRole("link", { name: "Sign in" })).toHaveAttribute(
      "href",
      "/sign-in"
    );

    view.unmount();
    renderLandingPage(true);
    const signedInHeader = screen.getByRole("banner");
    expect(within(signedInHeader).getByRole("link", { name: "Open workspace" })).toHaveAttribute(
      "href",
      "/app/"
    );
  });
});
