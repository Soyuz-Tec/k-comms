import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import {
  AppMenuCloseButton,
  AppMenuTrigger,
  AppSurfaceControlButton,
  AppSurfaceControlCluster
} from "./AppMenuControls";

describe("shared menu and surface controls", () => {
  it("exposes consistent dialog semantics on the hamburger trigger", async () => {
    const onClick = vi.fn();
    const user = userEvent.setup();
    render(
      <AppMenuTrigger
        accessibleLabel="Open main menu"
        controls="main-menu"
        expanded={false}
        onClick={onClick}
      />
    );

    const trigger = screen.getByRole("button", { name: "Open main menu" });
    expect(trigger).toHaveAttribute("aria-haspopup", "dialog");
    expect(trigger).toHaveAttribute("aria-controls", "main-menu");
    expect(trigger).toHaveAttribute("aria-expanded", "false");
    expect(trigger.querySelector(".app-icon")).toBeInTheDocument();
    await user.click(trigger);
    expect(onClick).toHaveBeenCalledOnce();
  });

  it("uses the same familiar close and state-control grammar", () => {
    render(
      <AppSurfaceControlCluster aria-label="Example controls">
        <AppSurfaceControlButton
          accessibleLabel="Minimize example"
          kind="minimize"
        />
        <AppSurfaceControlButton
          accessibleLabel="Expand example"
          kind="expand"
        />
        <AppMenuCloseButton accessibleLabel="Close example menu" />
      </AppSurfaceControlCluster>
    );

    expect(screen.getByRole("group", { name: "Example controls" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Minimize example" }))
      .toHaveAttribute("title", "Minimize example");
    expect(screen.getByRole("button", { name: "Expand example" }))
      .toHaveAttribute("title", "Expand example");
    expect(screen.getByRole("button", { name: "Close example menu" }))
      .toHaveTextContent("Close");
  });
});
