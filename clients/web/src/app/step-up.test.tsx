import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { ApiError } from "../api";
import { ActionDialog } from "../components/ActionDialog";
import { StepUpProvider, useStepUp } from "./step-up";

const stepUp = vi.hoisted(() => vi.fn());
vi.mock("./session", () => ({ useSession: () => ({ api: { stepUp } }) }));

function Harness({ action }: { action: () => Promise<string> }) {
  const { runWithStepUp } = useStepUp();
  const [result, setResult] = useState("");
  return <><button type="button" onClick={() => void runWithStepUp(action).then(setResult)}>Sensitive action</button><span>{result}</span></>;
}

describe("step-up retry", () => {
  it("retries a sensitive action after password verification without retaining the password", async () => {
    stepUp.mockReset().mockResolvedValue({ step_up_at: "2026-07-12T10:00:00Z" });
    const action = vi.fn()
      .mockRejectedValueOnce(new ApiError(403, "step_up_required", "Confirm it is you"))
      .mockResolvedValueOnce("completed");
    const user = userEvent.setup();
    render(<StepUpProvider><Harness action={action} /></StepUpProvider>);

    await user.click(screen.getByRole("button", { name: "Sensitive action" }));
    await user.type(screen.getByLabelText("Current password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Continue" }));

    expect(stepUp).toHaveBeenCalledWith("correct horse battery staple");
    expect(await screen.findByText("completed")).toBeVisible();
    expect(screen.queryByLabelText("Current password")).not.toBeInTheDocument();
  });

  it("keeps step-up accessible when a reviewed action starts from another modal", async () => {
    stepUp.mockReset().mockResolvedValue({ step_up_at: "2026-07-12T10:00:00Z" });
    const action = vi.fn()
      .mockRejectedValueOnce(new ApiError(403, "step_up_required", "Confirm it is you"))
      .mockResolvedValueOnce("completed");
    const user = userEvent.setup();
    render(<StepUpProvider><NestedDialogHarness action={action} /></StepUpProvider>);

    const opener = screen.getByRole("button", { name: "Review sensitive action" });
    await user.click(opener);
    await user.type(screen.getByRole("textbox", { name: "Reason for this change" }), "Approved test change");
    await user.click(screen.getByRole("button", { name: "Apply change" }));

    expect(await screen.findByRole("dialog", { name: "Confirm it is you" })).toBeVisible();
    await user.type(screen.getByLabelText("Current password"), "correct horse battery staple");
    await user.click(screen.getByRole("button", { name: "Continue" }));

    await waitFor(() => expect(action).toHaveBeenCalledTimes(2));
    expect(action).toHaveBeenLastCalledWith("Approved test change");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument());
    await waitFor(() => expect(opener).toHaveFocus());
  });
});

function NestedDialogHarness({ action }: { action: (reason: string) => Promise<string> }) {
  const { runWithStepUp } = useStepUp();
  const [open, setOpen] = useState(false);
  return <>
    <button type="button" onClick={() => setOpen(true)}>Review sensitive action</button>
    {open && <ActionDialog
      title="Apply sensitive change?"
      description="Synthetic reviewed action"
      confirmLabel="Apply change"
      auditReason={{ minimumLength: 3 }}
      onCancel={() => setOpen(false)}
      onConfirm={(reason) => void runWithStepUp(() => action(reason)).then(() => setOpen(false))}
    />}
  </>;
}
