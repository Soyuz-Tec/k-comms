import { useState } from "react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { BrowserRouter, MemoryRouter, useLocation, useNavigate } from "react-router";
import { describe, expect, it } from "vitest";
import { RouterHistoryProvider, useRouterHistory } from "./router-history";

function Controls() {
  const history = useRouterHistory();
  const navigate = useNavigate();
  const location = useLocation();
  const [nextStep, setNextStep] = useState(1);
  return <>
    <output aria-label="Current route">{location.pathname}</output>
    <button disabled={!history.canGoBack} onClick={history.onBack}>Back</button>
    <button disabled={!history.canGoForward} onClick={history.onForward}>Forward</button>
    <button onClick={history.onBack}>Guarded back</button>
    <button onClick={history.onForward}>Guarded forward</button>
    <button onClick={() => { void navigate("/two"); }}>Go two</button>
    <button onClick={() => { void navigate("/three"); }}>Go three</button>
    <button onClick={() => { void navigate("/one"); }}>Push same route</button>
    <button onClick={() => { void navigate("/replacement", { replace: true }); }}>Replace current</button>
    <button onClick={() => { void navigate("/branch"); }}>Push branch</button>
    <button onClick={() => { void navigate(-1); }}>Browser previous</button>
    <button onClick={() => { void navigate("/two"); void navigate("/three"); }}>Batched pushes</button>
    <button onClick={() => { void navigate(`/step/${nextStep}`); setNextStep(nextStep + 1); }}>Next step</button>
  </>;
}

function click(label: string) { fireEvent.click(screen.getByRole("button", { name: label })); }
function route(path: string) { expect(screen.getByLabelText("Current route")).toHaveTextContent(path); }
function controls(back: boolean, forward: boolean) {
  expect(screen.getByRole("button", { name: "Back" }).hasAttribute("disabled")).toBe(!back);
  expect(screen.getByRole("button", { name: "Forward" }).hasAttribute("disabled")).toBe(!forward);
}

describe("known router history", () => {
  it("does not claim unseen browser history on the initial visit", () => {
    render(<MemoryRouter initialEntries={["/outside", "/one", "/unseen-forward"]} initialIndex={1}>
      <RouterHistoryProvider><Controls /></RouterHistoryProvider>
    </MemoryRouter>);
    controls(false, false);
    click("Guarded back"); click("Guarded forward");
    route("/one");
  });

  it("follows observed pushes and both directions of POP traversal", () => {
    render(<MemoryRouter initialEntries={["/one"]}><RouterHistoryProvider><Controls /></RouterHistoryProvider></MemoryRouter>);
    click("Go two"); click("Go three"); controls(true, false);
    click("Back"); route("/two"); controls(true, true);
    click("Back"); route("/one"); controls(false, true);
    click("Forward"); route("/two"); controls(true, true);
    click("Forward"); route("/three"); controls(true, false);
  });

  it("preserves known forward entries when the current entry is replaced", () => {
    render(<MemoryRouter initialEntries={["/one"]}><RouterHistoryProvider><Controls /></RouterHistoryProvider></MemoryRouter>);
    click("Go two"); click("Go three"); click("Back"); click("Replace current");
    route("/replacement"); controls(true, true);
    click("Forward"); route("/three");
    click("Back"); route("/replacement");
    click("Back"); route("/one");
    click("Forward"); route("/replacement");
  });

  it("discards the old forward branch after a new push", () => {
    render(<MemoryRouter initialEntries={["/one"]}><RouterHistoryProvider><Controls /></RouterHistoryProvider></MemoryRouter>);
    click("Go two"); click("Go three"); click("Back"); click("Push branch");
    route("/branch"); controls(true, false);
    click("Guarded forward"); route("/branch");
    click("Back"); route("/two"); controls(true, true);
    click("Forward"); route("/branch");
  });

  it("distinguishes two visits to the same URL by their location keys", () => {
    render(<MemoryRouter initialEntries={["/one"]}><RouterHistoryProvider><Controls /></RouterHistoryProvider></MemoryRouter>);
    click("Push same route"); route("/one"); controls(true, false);
    click("Back"); route("/one"); controls(false, true);
    click("Forward"); route("/one"); controls(true, false);
  });

  it("resets safely when browser controls POP to an unknown entry", () => {
    render(<MemoryRouter initialEntries={["/outside", "/one"]} initialIndex={1}>
      <RouterHistoryProvider><Controls /></RouterHistoryProvider>
    </MemoryRouter>);
    click("Go two"); click("Browser previous"); route("/one"); controls(false, true);
    click("Browser previous"); route("/outside"); controls(false, false);
    click("Guarded forward"); route("/outside");
  });

  it("bounds retained entries without exposing back beyond the retained boundary", () => {
    render(<MemoryRouter initialEntries={["/step/0"]}><RouterHistoryProvider><Controls /></RouterHistoryProvider></MemoryRouter>);
    for (let index = 0; index < 100; index += 1) click("Next step");
    route("/step/100");
    for (let index = 0; index < 99; index += 1) click("Back");
    route("/step/1"); controls(false, true);
    click("Guarded back"); route("/step/1");
    click("Forward"); route("/step/2"); controls(true, true);
  });

  it("does not infer a known previous entry when BrowserRouter batches two pushes", async () => {
    window.history.replaceState({ idx: 20, key: "initial-known" }, "", "/one");
    render(<BrowserRouter><RouterHistoryProvider trackBrowserIndex><Controls /></RouterHistoryProvider></BrowserRouter>);
    controls(false, false);
    click("Batched pushes");
    await waitFor(() => route("/three"));
    controls(false, false);
    click("Guarded back"); route("/three");
  });
});
