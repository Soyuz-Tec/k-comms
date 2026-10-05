import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../api";
import { ActionDialog } from "../components/ActionDialog";
import { StepUpProvider, useStepUp } from "./step-up";

const { stepUp, stepUpOidc } = vi.hoisted(() => ({ stepUp: vi.fn(), stepUpOidc: vi.fn() }));
vi.mock("./session", () => ({ useSession: () => ({ api: { stepUp, stepUpOidc }, session: { tenant: { slug: "acme" } } }) }));

function Harness({ action }: { action: () => Promise<string> }) {
  const { runWithStepUp } = useStepUp();
  const [result, setResult] = useState("");
  return <><button type="button" onClick={() => void runWithStepUp(action).then(setResult)}>Sensitive action</button><span>{result}</span></>;
}

describe("step-up retry", () => {
  beforeEach(() => {
    stepUp.mockReset();
    stepUpOidc.mockReset();
    sessionStorage.clear();
    localStorage.clear();
  });

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

    expect(stepUp).toHaveBeenCalledWith("correct horse battery staple", undefined);
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

  it("requires successful password and MFA proof before retrying the pending action", async () => {
    stepUp.mockRejectedValueOnce(new ApiError(401, "invalid_mfa_code", "The code is invalid or already used."))
      .mockResolvedValueOnce({ step_up_at: "2026-10-04T10:00:00Z" });
    const action = vi.fn().mockRejectedValueOnce(new ApiError(403, "step_up_required", "Confirm it is you"))
      .mockResolvedValueOnce("completed");
    const user = userEvent.setup();
    render(<StepUpProvider><Harness action={action} /></StepUpProvider>);
    await user.click(screen.getByRole("button", { name: "Sensitive action" }));
    await user.type(screen.getByLabelText("Current password"), "memory-only-password");
    const code = screen.getByLabelText("Authenticator or recovery code, if enabled");
    await user.type(code, "111111");
    await user.click(screen.getByRole("button", { name: "Continue" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("The code is invalid or already used.");
    expect(action).toHaveBeenCalledTimes(1);
    expect(stepUp).toHaveBeenCalledWith("memory-only-password", "111111");
    await user.clear(code);
    await user.type(code, "654321");
    await user.click(screen.getByRole("button", { name: "Continue" }));
    expect(await screen.findByText("completed")).toBeVisible();
    expect(action).toHaveBeenCalledTimes(2);
    expect(stepUp).toHaveBeenLastCalledWith("memory-only-password", "654321");
    expect(JSON.stringify(sessionStorage)).not.toContain("memory-only-password");
    expect(JSON.stringify(localStorage)).not.toContain("memory-only-password");
  });

  it.each(["http://idp.example.test/authorize", "https://user:secret@idp.example.test/authorize", "javascript:alert(1)"])("rejects the unsafe corporate step-up address %s without retrying the action", async authorization_url => {
    stepUpOidc.mockResolvedValue({ authorization_url });
    const action = vi.fn().mockRejectedValue(new ApiError(403, "step_up_required", "Confirm it is you"));
    const user = userEvent.setup();
    render(<StepUpProvider><Harness action={action} /></StepUpProvider>);
    await user.click(screen.getByRole("button", { name: "Sensitive action" }));
    await user.click(screen.getByRole("button", { name: "Verify with corporate sign in" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("The corporate verification address could not be verified.");
    expect(stepUpOidc).toHaveBeenCalledWith("acme");
    expect(stepUp).not.toHaveBeenCalled();
    expect(action).toHaveBeenCalledTimes(1);
    expect(sessionStorage.getItem("kcomms:oidc-link")).toBeNull();
    expect(screen.getByText("After verification, return to this action and try again.")).toBeVisible();
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
