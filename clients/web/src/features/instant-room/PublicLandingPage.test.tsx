import { render, screen, within } from "@testing-library/react";
import { BrowserRouter } from "react-router";
import { describe, expect, it } from "vitest";
import { PublicLandingPage } from "./PublicLandingPage";

function renderLandingPage(signedIn = false) {
  return render(
    <BrowserRouter>
      <PublicLandingPage
        signedIn={signedIn}
        launcher={<section aria-label="Room launcher">Working room form</section>}
      />
    </BrowserRouter>
  );
}

describe("PublicLandingPage", () => {
  it("opens with a collaboration-first workspace launcher", () => {
    renderLandingPage();

    expect(
      screen.getByRole("heading", {
        name: "Message. Draw. Share."
      })
    ).toBeVisible();
    expect(screen.getByText("Instant collaboration")).toBeVisible();
    expect(screen.getByRole("region", { name: "Room launcher" })).toHaveTextContent(
      "Working room form"
    );
    expect(screen.getByText("Live conversation")).toBeVisible();
    expect(screen.getByText("Shared drawing canvas")).toBeVisible();
    expect(screen.getByText("QR and invitation link")).toBeVisible();
  });

  it("shows the message-and-canvas workspace before room creation", () => {
    renderLandingPage();

    const preview = screen.getByRole("region", {
      name: "K-Comms workspace preview"
    });
    expect(within(preview).getByText("Ideas stay visible")).toBeVisible();
    expect(within(preview).getByText("Message the room")).toBeVisible();
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
