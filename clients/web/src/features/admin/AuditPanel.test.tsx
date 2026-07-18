import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { StepUpProvider } from "../../app/step-up";
import type { AuditEvent } from "../../types";
import { AuditPanel } from "./AuditPanel";

vi.mock("../../app/session", () => ({ useSession: () => ({ api: { stepUp: vi.fn() } }) }));

afterEach(() => vi.restoreAllMocks());

describe("AuditPanel export", () => {
  it("exports the active filter and announces a capped CSV download", async () => {
    const event: AuditEvent = {
      id: "audit-1",
      actor_user_id: "user-1",
      action: "user.created",
      resource_type: "user",
      resource_id: "user-2",
      metadata: {},
      request_id: "request-1",
      inserted_at: "2026-07-12T10:00:00Z"
    };
    const exportAuditEvents = vi.fn().mockResolvedValue({
      blob: new Blob(["\"action\"\r\n\"user.created\"\r\n"], { type: "text/csv" }),
      filename: "k-comms-audit-20260712T100000Z.csv",
      count: 5_000,
      truncated: true
    });
    const api = {
      auditEvents: vi.fn().mockResolvedValue([event]),
      exportAuditEvents
    } as unknown as ApiClient;
    const createObjectURL = vi.fn().mockReturnValue("blob:audit-export");
    const revokeObjectURL = vi.fn();
    Object.defineProperty(URL, "createObjectURL", { value: createObjectURL, configurable: true });
    Object.defineProperty(URL, "revokeObjectURL", { value: revokeObjectURL, configurable: true });
    const click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined);
    const user = userEvent.setup();
    render(<StepUpProvider><AuditPanel api={api} users={[]} /></StepUpProvider>);

    await user.type(screen.getByLabelText("Filter loaded events"), "user.created");
    await user.click(screen.getByRole("button", { name: "Export audit CSV" }));

    expect(exportAuditEvents).toHaveBeenCalledWith({ q: "user.created", limit: 5_000 });
    expect(createObjectURL).toHaveBeenCalledWith(expect.any(Blob));
    expect(click).toHaveBeenCalledOnce();
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:audit-export");
    expect(await screen.findByRole("status")).toHaveTextContent("Downloaded 5000 audit events");
    expect(screen.getByRole("status")).toHaveTextContent("5,000-row limit");
  });
});
