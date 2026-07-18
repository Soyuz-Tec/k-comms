import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { ActionDialog, ConfirmDialog } from "./ActionDialog";

function Harness({ onConfirm, requireReason = false }: { onConfirm: (reason: string) => void; requireReason?: boolean }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <main><button type="button" onClick={() => setOpen(true)}>Remove member</button></main>
      {open && (
        <ActionDialog
          title="Remove this member?"
          description="They will immediately lose workspace access."
          impact="Their account is suspended and the change is written to the audit log."
          confirmLabel="Remove member"
          tone="danger"
          auditReason={requireReason ? { minimumLength: 5, helpText: "This reason will be visible to auditors." } : undefined}
          onCancel={() => setOpen(false)}
          onConfirm={onConfirm}
        />
      )}
    </>
  );
}

describe("ActionDialog", () => {
  it("isolates background content, contains focus, closes with Escape and restores focus", async () => {
    const user = userEvent.setup();
    const { container } = render(<Harness onConfirm={vi.fn()} />);
    const trigger = screen.getByRole("button", { name: "Remove member" });

    await user.click(trigger);
    const cancel = screen.getByRole("button", { name: "Cancel" });
    const confirm = screen.getByRole("button", { name: "Remove member" });
    await waitFor(() => expect(cancel).toHaveFocus());
    expect(container).toHaveAttribute("aria-hidden", "true");
    expect((container as HTMLElement).inert).toBe(true);

    await user.tab();
    expect(confirm).toHaveFocus();
    await user.tab();
    expect(cancel).toHaveFocus();

    await user.keyboard("{Escape}");
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    await waitFor(() => expect(trigger).toHaveFocus());
    expect(container).not.toHaveAttribute("aria-hidden");
    expect((container as HTMLElement).inert).toBe(false);
  });

  it("requires and returns a trimmed audit reason", async () => {
    const onConfirm = vi.fn();
    const user = userEvent.setup();
    render(<Harness onConfirm={onConfirm} requireReason />);

    await user.click(screen.getByRole("button", { name: "Remove member" }));
    await user.click(screen.getByRole("button", { name: "Remove member" }));
    expect(screen.getByText("Enter a reason of at least 5 characters.")).toBeVisible();
    expect(onConfirm).not.toHaveBeenCalled();

    await user.type(screen.getByLabelText("Reason for this change"), "  Left the company  ");
    await user.click(screen.getByRole("button", { name: "Remove member" }));
    expect(onConfirm).toHaveBeenCalledWith("Left the company");
  });

  it("keeps focus and Escape handling with the topmost stacked dialog", async () => {
    function StackedHarness() {
      const [outerOpen, setOuterOpen] = useState(false);
      const [innerOpen, setInnerOpen] = useState(false);
      return <>
        <button type="button" onClick={() => setOuterOpen(true)}>Open review</button>
        {outerOpen && <ActionDialog title="Review change" description="Review the requested change." confirmLabel="Continue" onCancel={() => setOuterOpen(false)} onConfirm={() => setInnerOpen(true)} />}
        {innerOpen && <ConfirmDialog title="Verify identity" description="A second confirmation is required." confirmLabel="Verify" onCancel={() => setInnerOpen(false)} onConfirm={() => setInnerOpen(false)} />}
      </>;
    }

    const user = userEvent.setup();
    render(<StackedHarness />);
    await user.click(screen.getByRole("button", { name: "Open review" }));
    await user.click(screen.getByRole("button", { name: "Continue" }));
    expect(screen.getByRole("alertdialog", { name: "Verify identity" })).toBeVisible();

    await user.keyboard("{Escape}");
    expect(screen.queryByRole("alertdialog", { name: "Verify identity" })).not.toBeInTheDocument();
    expect(screen.getByRole("alertdialog", { name: "Review change" })).toBeVisible();
    await waitFor(() => expect(screen.getByRole("button", { name: "Continue" })).toHaveFocus());

    await user.keyboard("{Escape}");
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });
});
