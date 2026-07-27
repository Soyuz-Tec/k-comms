import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AppIcon } from "./AppIcon";

describe("AppIcon", () => {
  it("keeps decorative icons out of the accessibility tree", () => {
    const { container } = render(<AppIcon name="message" />);

    expect(container.querySelector("svg")).toHaveAttribute("aria-hidden", "true");
  });

  it("exposes an explicitly labelled icon", () => {
    render(<AppIcon name="triangleAlert" aria-label="Warning" />);

    expect(screen.getByRole("img", { name: "Warning" })).toBeInTheDocument();
  });
});
