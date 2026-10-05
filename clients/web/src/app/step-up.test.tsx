import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../api";
import { ActionDialog } from "../components/ActionDialog";
import { StepUpProvider, stepUpWasCancelled, useStepUp } from "./step-up";

const { stepUp, stepUpOidc } = vi.hoisted(() => ({ stepUp: vi.fn(), stepUpOidc: vi.fn() }));
const identity = vi.hoisted(() => ({ tenantId: "tenant-1", userId: "owner-1", deviceId: "device-1", role: "owner", version: 1, accessToken: "credential-1" }));
vi.mock("./session", () => ({ useSession: () => ({ api: { stepUp, stepUpOidc }, session: {
  tenant: { id: identity.tenantId, slug: "acme" }, user: { id: identity.userId, role: identity.role, version: identity.version, status: "active", account_type: "human", access_scope: "workspace" },
  device: { id: identity.deviceId }, access_token: identity.accessToken
} }) }));

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}
function ConcurrentHarness({ actions, settled }: { actions: (() => Promise<string>)[]; settled: (result: string) => void }) {
  const { runWithStepUp } = useStepUp();
  return <button onClick={() => actions.forEach(action => {
    void runWithStepUp(action).then(settled, reason => settled(stepUpWasCancelled(reason) ? "cancelled" : "failed"));
  })}>Concurrent actions</button>;
}

function Harness({ action }: { action: () => Promise<string> }) {
  const { runWithStepUp } = useStepUp();
  const [result, setResult] = useState("");
  return <><button type="button" onClick={() => void runWithStepUp(action).then(setResult, reason => {
    if (!stepUpWasCancelled(reason)) setResult("failed");
  })}>Sensitive action</button><span>{result}</span></>;
}

describe("step-up retry", () => {
  beforeEach(() => {
    stepUp.mockReset();
    stepUpOidc.mockReset();
    sessionStorage.clear();
    localStorage.clear();
    Object.assign(identity, { tenantId: "tenant-1", userId: "owner-1", deviceId: "device-1", role: "owner", version: 1, accessToken: "credential-1" });
  });

  it("shares one proof between reverse-order concurrent 428 callers and settles both retries", async () => {
    const old = deferred<string>(); const current = deferred<string>();
    const first = vi.fn().mockReturnValueOnce(old.promise).mockResolvedValueOnce("first completed");
    const second = vi.fn().mockReturnValueOnce(current.promise).mockResolvedValueOnce("second completed");
    const settled = vi.fn(); stepUp.mockResolvedValue({ step_up_at: "now" });
    render(<StepUpProvider><ConcurrentHarness actions={[first, second]} settled={settled} /></StepUpProvider>);
    await userEvent.click(screen.getByRole("button", { name: "Concurrent actions" }));
    await act(async () => { current.reject(new ApiError(428, "step_up_required", "Verify")); });
    await act(async () => { old.reject(new ApiError(428, "step_up_required", "Verify")); });
    expect(screen.getAllByRole("dialog", { name: "Confirm it is you" })).toHaveLength(1);
    await userEvent.type(screen.getByLabelText("Current password"), "proof-password");
    await userEvent.click(screen.getByRole("button", { name: "Continue" }));
    await waitFor(() => expect(settled).toHaveBeenCalledTimes(2));
    expect(settled).toHaveBeenCalledWith("first completed"); expect(settled).toHaveBeenCalledWith("second completed");
    expect(stepUp).toHaveBeenCalledTimes(1); expect(first).toHaveBeenCalledTimes(2); expect(second).toHaveBeenCalledTimes(2);
  });

  it("cancels every concurrent waiter and does not reopen proof for an in-flight late 428", async () => {
    const late = deferred<string>();
    const first = vi.fn().mockRejectedValue(new ApiError(428, "step_up_required", "Verify"));
    const second = vi.fn().mockReturnValue(late.promise); const settled = vi.fn();
    render(<StepUpProvider><ConcurrentHarness actions={[first, second]} settled={settled} /></StepUpProvider>);
    await userEvent.click(screen.getByRole("button", { name: "Concurrent actions" }));
    await userEvent.click(await screen.findByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(settled).toHaveBeenCalledTimes(2));
    expect(settled.mock.calls).toEqual([["cancelled"], ["cancelled"]]);
    await act(async () => { late.reject(new ApiError(428, "step_up_required", "Verify")); });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(stepUp).not.toHaveBeenCalled(); expect(first).toHaveBeenCalledTimes(1); expect(second).toHaveBeenCalledTimes(1);
  });

  it.each(["user", "credential", "role", "version"])("rejects all waiters after current actor %s changes and ignores old proof completion", async change => {
    const proof = deferred<{ step_up_at: string }>(); stepUp.mockReturnValue(proof.promise);
    const first = vi.fn().mockRejectedValue(new ApiError(428, "step_up_required", "Verify"));
    const second = vi.fn().mockRejectedValue(new ApiError(428, "step_up_required", "Verify")); const settled = vi.fn();
    const view = render(<StepUpProvider><ConcurrentHarness actions={[first, second]} settled={settled} /></StepUpProvider>);
    await userEvent.click(screen.getByRole("button", { name: "Concurrent actions" }));
    await userEvent.type(await screen.findByLabelText("Current password"), "old-proof");
    await userEvent.click(screen.getByRole("button", { name: "Continue" }));
    if (change === "user") identity.userId = "owner-2";
    if (change === "credential") identity.accessToken = "credential-2";
    if (change === "role") identity.role = "admin";
    if (change === "version") identity.version = 2;
    view.rerender(<StepUpProvider><ConcurrentHarness actions={[first, second]} settled={settled} /></StepUpProvider>);
    await waitFor(() => expect(settled).toHaveBeenCalledTimes(2));
    expect(settled.mock.calls).toEqual([["cancelled"], ["cancelled"]]);
    await act(async () => { proof.resolve({ step_up_at: "now" }); });
    expect(first).toHaveBeenCalledTimes(1); expect(second).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument(); expect(stepUp).toHaveBeenCalledTimes(1);
  });

  it("rejects every waiter on provider unmount", async () => {
    const action = vi.fn().mockRejectedValue(new ApiError(428, "step_up_required", "Verify")); const settled = vi.fn();
    const view = render(<StepUpProvider><ConcurrentHarness actions={[action, action]} settled={settled} /></StepUpProvider>);
    await userEvent.click(screen.getByRole("button", { name: "Concurrent actions" }));
    await screen.findByRole("dialog"); view.unmount();
    await waitFor(() => expect(settled.mock.calls).toEqual([["cancelled"], ["cancelled"]]));
    expect(stepUp).not.toHaveBeenCalled(); expect(action).toHaveBeenCalledTimes(2);
  });

  it("uses the completed shared proof for a late initial 428 without starting another proof", async () => {
    const late = deferred<string>(); const first = vi.fn().mockRejectedValueOnce(new ApiError(428, "step_up_required", "Verify")).mockResolvedValueOnce("first");
    const second = vi.fn().mockReturnValueOnce(late.promise).mockResolvedValueOnce("second"); const settled = vi.fn(); stepUp.mockResolvedValue({ step_up_at: "now" });
    render(<StepUpProvider><ConcurrentHarness actions={[first, second]} settled={settled} /></StepUpProvider>);
    await userEvent.click(screen.getByRole("button", { name: "Concurrent actions" }));
    await userEvent.type(await screen.findByLabelText("Current password"), "proof-password");
    await userEvent.click(screen.getByRole("button", { name: "Continue" }));
    await waitFor(() => expect(settled).toHaveBeenCalledWith("first"));
    await act(async () => { late.reject(new ApiError(428, "step_up_required", "Verify")); });
    await waitFor(() => expect(settled).toHaveBeenCalledWith("second"));
    expect(stepUp).toHaveBeenCalledTimes(1); expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("rejects a retry's second 428 without automatically repeating proof", async () => {
    const action = vi.fn().mockRejectedValue(new ApiError(428, "step_up_required", "Verify")); const settled = vi.fn(); stepUp.mockResolvedValue({ step_up_at: "now" });
    render(<StepUpProvider><ConcurrentHarness actions={[action]} settled={settled} /></StepUpProvider>);
    await userEvent.click(screen.getByRole("button", { name: "Concurrent actions" }));
    await userEvent.type(await screen.findByLabelText("Current password"), "proof-password");
    await userEvent.click(screen.getByRole("button", { name: "Continue" }));
    await waitFor(() => expect(settled).toHaveBeenCalledWith("failed"));
    expect(action).toHaveBeenCalledTimes(2); expect(stepUp).toHaveBeenCalledTimes(1); expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
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
      onConfirm={(reason) => void runWithStepUp(() => action(reason)).then(() => setOpen(false), failure => {
        if (!stepUpWasCancelled(failure)) setOpen(false);
      })}
    />}
  </>;
}
