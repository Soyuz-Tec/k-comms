import { useState } from "react";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { createBrowserRouter, createMemoryRouter, Link, Navigate, Outlet, RouterProvider, useLocation, useNavigate } from "react-router";
import { afterEach, describe, expect, it } from "vitest";
import { RouterHistoryProvider, useRouterHistory } from "./router-history";
import { UnsavedWorkProvider, useUnsavedWork } from "./UnsavedWork";

let changeAuthority: (value: string | null) => void;
let saveWork: () => void;
const routers: Array<ReturnType<typeof createMemoryRouter>> = [];
afterEach(() => { routers.splice(0).forEach(router => router.dispose()); });
function Work() {
  const [draft, setDraft] = useState("");
  saveWork = () => setDraft("");
  useUnsavedWork(Boolean(draft), "Your local draft has not been sent.");
  return <input aria-label="Draft" value={draft} onChange={event => setDraft(event.target.value)} />;
}
function HistoryControls() {
  const { canGoBack, canGoForward, onBack, onForward } = useRouterHistory();
  const navigate = useNavigate();
  const location = useLocation();
  return <>
    <output aria-label="Location">{location.pathname}{location.search}{location.hash}</output>
    <button disabled={!canGoBack} onClick={onBack}>Back</button><button disabled={!canGoForward} onClick={onForward}>Forward</button>
    <button onClick={() => void navigate("/other?target=2#result", { replace: true })}>Replace</button>
    <Link to="/other?target=1#result">Other</Link><Link to="/work?document=2#editor">Another document</Link><Link to="/work?document=1#details">Details</Link>
  </>;
}
function Fixture({ expiredRedirect = false, browser = false }: { expiredRedirect?: boolean; browser?: boolean }) {
  const [authority, setAuthority] = useState<string | null>("first");
  changeAuthority = setAuthority;
  return <UnsavedWorkProvider authority={authority}><RouterHistoryProvider trackBrowserIndex={browser}>
    <HistoryControls />
    {expiredRedirect && authority === null ? <Navigate to="/sign-in" replace /> : <div key={authority}><Outlet /></div>}
  </RouterHistoryProvider></UnsavedWorkProvider>;
}
function open({ browser = false, expiredRedirect = false } = {}) {
  if (browser) window.history.replaceState(null, "", "/work?document=1#editor");
  const routes = [{ element: <Fixture browser={browser} expiredRedirect={expiredRedirect} />, children: [
    { path: "/work", element: <Work /> }, { path: "/other", element: <h1>Other page</h1> }, { path: "/sign-in", element: <h1>Sign in</h1> }
  ] }];
  const router = browser ? createBrowserRouter(routes) : createMemoryRouter(routes, { initialEntries: ["/work?document=1#editor"] });
  routers.push(router); render(<RouterProvider router={router} />); return router;
}
function typeDraft() { fireEvent.change(screen.getByLabelText("Draft"), { target: { value: "Local draft" } }); }

describe("unfinished work navigation", () => {
  it("preserves the current resource and exact requested deep link until explicit discard", async () => {
    const user = userEvent.setup(); const router = open(); typeDraft();
    await user.click(screen.getByRole("link", { name: "Another document" }));
    expect(router.state.location.search).toBe("?document=1");
    expect(screen.getByRole("alertdialog")).toHaveTextContent("Already submitted actions may still complete");
    await user.click(screen.getByRole("button", { name: "Stay here" }));
    expect(screen.getByLabelText("Draft")).toHaveValue("Local draft");
    await user.click(screen.getByRole("link", { name: "Other" }));
    await user.click(screen.getByRole("button", { name: "Leave and discard" }));
    expect(screen.getByLabelText("Location")).toHaveTextContent("/other?target=1#result");
    expect(screen.queryByLabelText("Draft")).not.toBeInTheDocument();
  });
  it("protects programmatic replacements and cancels safely with Escape", async () => {
    const user = userEvent.setup(); const router = open(); typeDraft();
    await user.click(screen.getByRole("button", { name: "Replace" }));
    await user.keyboard("{Escape}");
    expect(router.state.location.pathname).toBe("/work");
    expect(screen.getByLabelText("Draft")).toHaveValue("Local draft");
  });
  it("preserves history position when Back is cancelled and enables Forward after confirmed Back", async () => {
    const user = userEvent.setup(); const router = open();
    await act(() => router.navigate("/other")); await act(() => router.navigate("/work?document=1#editor")); typeDraft();
    await user.click(screen.getByRole("button", { name: "Back" }));
    await user.click(screen.getByRole("button", { name: "Stay here" }));
    expect(screen.getByRole("button", { name: "Forward" })).toBeDisabled();
    await user.click(screen.getByRole("button", { name: "Back" }));
    await user.click(screen.getByRole("button", { name: "Leave and discard" }));
    expect(screen.getByRole("heading", { name: "Other page" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Forward" }));
    expect(screen.getByLabelText("Draft")).toHaveValue("");
    expect(screen.getByLabelText("Location")).toHaveTextContent("/work?document=1#editor");
  });
  it("blocks native browser Back and restores the address until explicit confirmation", async () => {
    const user = userEvent.setup(); const router = open({ browser: true });
    await act(() => router.navigate("/other")); await act(() => router.navigate("/work?document=1#editor")); typeDraft();
    act(() => window.history.back());
    await screen.findByRole("alertdialog");
    await waitFor(() => expect(window.location.pathname).toBe("/work"));
    await user.click(screen.getByRole("button", { name: "Leave and discard" }));
    await screen.findByRole("heading", { name: "Other page" });
    expect(window.location.pathname).toBe("/other");
  });
  it("allows fragment navigation without discarding the mounted resource", async () => {
    open(); typeDraft(); fireEvent.click(screen.getByRole("link", { name: "Details" }));
    expect(screen.getByLabelText("Draft")).toHaveValue("Local draft");
    expect(screen.getByLabelText("Location")).toHaveTextContent("#details");
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });
  it("never blocks expiry redirects and clears the old confirmation", async () => {
    const router = open({ expiredRedirect: true }); typeDraft(); fireEvent.click(screen.getByRole("link", { name: "Other" }));
    expect(screen.getByRole("alertdialog")).toBeVisible();
    act(() => changeAuthority(null));
    await waitFor(() => expect(router.state.location.pathname).toBe("/sign-in"));
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Draft")).not.toBeInTheDocument();
  });
  it("does not carry one workspace's guard or text into a different authority", async () => {
    const router = open(); typeDraft();
    act(() => changeAuthority("another-workspace"));
    expect(screen.getByLabelText("Draft")).toHaveValue("");
    await act(() => router.navigate("/other?workspace=next#item"));
    expect(screen.getByLabelText("Location")).toHaveTextContent("/other?workspace=next#item");
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });
  it("removes a stale confirmation when the server confirms all work", async () => {
    open(); typeDraft(); fireEvent.click(screen.getByRole("link", { name: "Other" }));
    expect(screen.getByRole("alertdialog")).toBeVisible();
    act(() => saveWork());
    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument());
    fireEvent.click(screen.getByRole("link", { name: "Other" }));
    expect(screen.getByRole("heading", { name: "Other page" })).toBeVisible();
  });
  it("warns before page unload only while local work exists", () => {
    open(); typeDraft();
    const dirty = new Event("beforeunload", { cancelable: true }); window.dispatchEvent(dirty);
    expect(dirty.defaultPrevented).toBe(true);
    act(() => saveWork());
    const clean = new Event("beforeunload", { cancelable: true }); window.dispatchEvent(clean);
    expect(clean.defaultPrevented).toBe(false);
  });
});
