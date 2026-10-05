import type { FormEvent } from "react";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { AdminCreateDisclosure } from "./AdminCreateDisclosure";

describe("administration creation disclosure", () => {
  it("starts with inventory visible and preserves a draft through collapse and reopening", async () => {
    const submit = vi.fn((event: FormEvent) => event.preventDefault());
    const user = userEvent.setup();
    render(<><p>Existing resources remain visible.</p><AdminCreateDisclosure label="New resource"><form onSubmit={submit}><label>Resource name<input name="name" /></label><button type="submit">Create resource</button></form></AdminCreateDisclosure></>);

    expect(screen.getByText("Existing resources remain visible.")).toBeVisible();
    expect(screen.getByRole("button", { name: "Create resource" })).not.toBeVisible();
    await user.tab();
    expect(screen.getByText("New resource").closest("summary")).toHaveFocus();
    await user.click(screen.getByText("New resource"));
    await user.type(screen.getByRole("textbox", { name: "Resource name" }), "Release automation");
    await user.click(screen.getByText("New resource"));
    expect(screen.getByRole("textbox", { name: "Resource name" })).not.toBeVisible();
    expect(screen.getByText("Existing resources remain visible.")).toBeVisible();
    await user.click(screen.getByText("New resource"));
    expect(screen.getByRole("textbox", { name: "Resource name" })).toHaveValue("Release automation");
    expect(submit).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Create resource" }));
    expect(submit).toHaveBeenCalledOnce();
  });
});
