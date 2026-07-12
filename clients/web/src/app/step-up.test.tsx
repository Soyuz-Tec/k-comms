import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { ApiError } from "../api";
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
});
