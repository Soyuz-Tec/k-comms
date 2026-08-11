import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AuthenticationCanvasPage } from "./AuthenticationCanvasPage";

describe("AuthenticationCanvasPage", () => {
  it("keeps the canvas visible but inert behind the authentication gateway", () => {
    render(
      <AuthenticationCanvasPage
        workspace={<div data-testid="local-canvas">Local canvas</div>}
        gateway={<section aria-label="Authentication gateway">Sign in</section>}
      />
    );

    const canvas = screen.getByTestId("authentication-canvas");
    expect(canvas).toHaveAttribute("aria-hidden", "true");
    expect(canvas).toHaveAttribute("inert", "");
    expect(screen.getByTestId("local-canvas")).toBeInTheDocument();
    expect(screen.getByRole("region", { name: "Authentication gateway" })).toBeVisible();
  });
});
