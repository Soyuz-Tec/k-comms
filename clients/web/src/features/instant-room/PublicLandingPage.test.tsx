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
  it("presents the available collaboration product and working room entry", () => {
    renderLandingPage();

    expect(
      screen.getByRole("heading", {
        name: /One place to talk,\s*meet, and make\./
      })
    ).toBeVisible();
    expect(screen.getByText("Web app available now")).toBeVisible();
    expect(screen.getByRole("region", { name: "Room launcher" })).toHaveTextContent(
      "Working room form"
    );

    const product = document.getElementById("product");
    expect(product).not.toBeNull();
    expect(within(product!).getByText("Messaging that stays organized")).toBeVisible();
    expect(within(product!).getByText("Calls built into the work")).toBeVisible();
    expect(within(product!).getByText("A canvas everyone can shape")).toBeVisible();
    expect(within(product!).getByText("Files where people need them")).toBeVisible();
  });

  it("labels released web experiences separately from unreleased native packages", () => {
    renderLandingPage();

    const apps = document.getElementById("apps");
    expect(apps).not.toBeNull();
    expect(within(apps!).getByRole("heading", { name: "Desktop web app" })).toBeVisible();
    expect(within(apps!).getByRole("heading", { name: "Mobile web app" })).toBeVisible();
    expect(within(apps!).getAllByText("Available now")).toHaveLength(2);
    expect(within(apps!).getByRole("heading", { name: "Native app packages" })).toBeVisible();
    expect(within(apps!).getByText("Roadmap")).toBeVisible();
    expect(
      within(apps!).getByText(/planned, not released yet/i)
    ).toBeVisible();
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
