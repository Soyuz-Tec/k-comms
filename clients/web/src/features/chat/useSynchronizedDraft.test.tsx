import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { DraftSyncNotice } from "./DraftSyncNotice";
import { useSynchronizedDraft } from "./useSynchronizedDraft";

function Harness({ api, local = "" }: { api: ApiClient; local?: string }) {
  const [body, setBody] = useState(local);
  const sync = useSynchronizedDraft(api, "conv", "main", body, setBody);
  return <><textarea aria-label="Draft" value={body} onChange={event => { sync.edited(); setBody(event.target.value); }} /><DraftSyncNotice sync={sync} /></>;
}
describe("cross-device draft conflict", () => {
  it("hydrates a clean local composer from the remote version", async () => {
    const messageDraft = vi.fn().mockResolvedValue({ body: "remote draft", version: 3 });
    render(<Harness api={{ messageDraft } as unknown as ApiClient} />);
    await waitFor(() => expect(screen.getByRole("textbox")).toHaveValue("remote draft"));
  });
  it("does not recreate a draft that another device cleared", async () => {
    const messageDraft = vi.fn().mockResolvedValue({ body: "", version: 4 });
    render(<Harness local="old cached text" api={{ messageDraft } as unknown as ApiClient} />);
    expect(await screen.findByText(/different draft was saved/)).toBeVisible();
    expect(screen.getByRole("textbox")).toHaveValue("old cached text");
  });
  it("preserves divergent local text until the user chooses which version to use", async () => {
    const messageDraft = vi.fn().mockResolvedValue({ body: "other device", version: 3 });
    render(<Harness local="local text" api={{ messageDraft } as unknown as ApiClient} />);
    expect(await screen.findByText(/different draft was saved/)).toBeVisible();
    expect(screen.getByRole("textbox")).toHaveValue("local text");
    await userEvent.setup().click(screen.getByRole("button", { name: "Use other device’s draft" }));
    expect(screen.getByRole("textbox")).toHaveValue("other device");
  });
});
