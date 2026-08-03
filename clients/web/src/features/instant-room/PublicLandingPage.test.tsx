import { render, screen } from "@testing-library/react";
import { BrowserRouter } from "react-router";
import { describe, expect, it } from "vitest";
import { PublicLandingPage } from "./PublicLandingPage";

function renderLandingPage() {
  return render(
    <BrowserRouter>
      <PublicLandingPage
        workspace={
          <section aria-label="Working workspace">
            <h1>Message. Draw. Share.</h1>
            <div aria-label="Local drawing canvas">Canvas</div>
            <div aria-label="Room setup">Room setup</div>
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
    expect(screen.queryByRole("banner")).not.toBeInTheDocument();
    expect(screen.getByRole("region", { name: "Working workspace" })).toBeVisible();
    expect(screen.getByLabelText("Local drawing canvas")).toBeVisible();
    expect(screen.getByLabelText("Room setup")).toBeVisible();
  });

  it("shows the message-and-canvas workspace without surrounding chrome", () => {
    renderLandingPage();

    expect(screen.getByLabelText("Local drawing canvas")).toHaveTextContent("Canvas");
    expect(screen.getByLabelText("Room setup")).toHaveTextContent("Room setup");
    expect(screen.queryByRole("banner")).not.toBeInTheDocument();
    expect(screen.queryByRole("contentinfo")).not.toBeInTheDocument();
  });
});
