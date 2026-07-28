import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { PwaProvider, usePwa } from "./PwaProvider";
import { resetPwaRegistrationForTests } from "./registration";

afterEach(() => {
  resetPwaRegistrationForTests();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  Reflect.deleteProperty(navigator, "serviceWorker");
  Reflect.deleteProperty(navigator, "standalone");
});

describe("PwaProvider", () => {
  it("captures the native install prompt and reports the accepted choice", async () => {
    installBrowser();
    renderPwa();
    expect(screen.getByLabelText("Install mode")).toHaveTextContent(
      "manual-browser"
    );

    const prompt = vi.fn().mockResolvedValue(undefined);
    const event = Object.assign(new Event("beforeinstallprompt", {
      cancelable: true
    }), {
      prompt,
      userChoice: Promise.resolve({
        outcome: "accepted" as const,
        platform: "web"
      })
    });

    act(() => window.dispatchEvent(event));
    expect(event.defaultPrevented).toBe(true);
    expect(screen.getByLabelText("Install mode")).toHaveTextContent(
      "native-prompt"
    );

    await userEvent.click(screen.getByRole("button", { name: "Install" }));

    expect(prompt).toHaveBeenCalledTimes(1);
    expect(await screen.findByLabelText("Install result")).toHaveTextContent(
      "accepted"
    );
    expect(screen.getByLabelText("Install mode")).toHaveTextContent("installed");
  });

  it("returns iOS and browser-specific manual install fallbacks", async () => {
    installBrowser();
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)"
    );
    const view = renderPwa();

    expect(screen.getByLabelText("Install mode")).toHaveTextContent(
      "manual-ios"
    );
    await userEvent.click(screen.getByRole("button", { name: "Install" }));
    expect(screen.getByLabelText("Install result")).toHaveTextContent(
      "manual-ios"
    );

    view.unmount();
    resetPwaRegistrationForTests();
    vi.restoreAllMocks();
    installBrowser();
    renderPwa();

    await userEvent.click(screen.getByRole("button", { name: "Install" }));
    expect(screen.getByLabelText("Install result")).toHaveTextContent(
      "manual-browser"
    );
  });

  it("reports an already installed app and does not expose an install action", () => {
    installBrowser({ standalone: true });
    renderPwa();

    expect(screen.getByLabelText("Install mode")).toHaveTextContent("installed");
    expect(screen.queryByRole("button", { name: "Install" })).not.toBeInTheDocument();
  });

  it("fails closed after registration failure and retries when connectivity returns", async () => {
    const registration = installBrowser();
    const register = vi.mocked(navigator.serviceWorker.register);
    register
      .mockReset()
      .mockRejectedValueOnce(new Error("registration failed"))
      .mockResolvedValue(registration);
    renderPwa();

    await waitFor(() =>
      expect(screen.getByLabelText("Install mode")).toHaveTextContent(
        "unavailable"
      )
    );
    expect(register).toHaveBeenCalledTimes(1);

    act(() => window.dispatchEvent(new Event("online")));

    await waitFor(() => expect(register).toHaveBeenCalledTimes(2));
    await waitFor(() =>
      expect(screen.getByLabelText("Install mode")).toHaveTextContent(
        "manual-browser"
      )
    );
  });

  it("falls back to manual guidance when the native prompt rejects", async () => {
    installBrowser();
    renderPwa();
    const event = Object.assign(new Event("beforeinstallprompt", {
      cancelable: true
    }), {
      prompt: vi.fn().mockRejectedValue(new Error("prompt unavailable")),
      userChoice: Promise.resolve({
        outcome: "dismissed" as const,
        platform: "web"
      })
    });

    act(() => window.dispatchEvent(event));
    await userEvent.click(screen.getByRole("button", { name: "Install" }));

    expect(await screen.findByLabelText("Install result")).toHaveTextContent(
      "manual-browser"
    );
    expect(screen.getByLabelText("Install mode")).toHaveTextContent(
      "manual-browser"
    );
  });

  it("exposes waiting updates, applies them explicitly, and supports dismissal", async () => {
    const waiting = serviceWorker();
    const registration = installBrowser({ waiting });
    renderPwa();

    await waitFor(() =>
      expect(screen.getByLabelText("Update available")).toHaveTextContent("true")
    );
    expect(waiting.postMessage).not.toHaveBeenCalled();

    await userEvent.click(screen.getByRole("button", { name: "Dismiss update" }));
    expect(screen.getByLabelText("Update available")).toHaveTextContent("false");
    act(() => window.dispatchEvent(new Event("online")));
    await waitFor(() => expect(registration.update).toHaveBeenCalled());
    expect(screen.getByLabelText("Update available")).toHaveTextContent("false");
    expect(waiting.postMessage).not.toHaveBeenCalled();

    const replacement = serviceWorker();
    registration.waiting = replacement.worker;
    registration.dispatchEvent(new Event("updatefound"));
    replacement.worker.dispatchEvent(new Event("statechange"));
    await waitFor(() =>
      expect(screen.getByLabelText("Update available")).toHaveTextContent("true")
    );

    await userEvent.click(screen.getByRole("button", { name: "Apply update" }));
    expect(replacement.postMessage).toHaveBeenCalledWith({
      type: "SKIP_WAITING"
    });
    expect(screen.getByLabelText("Update available")).toHaveTextContent("false");
  });
});

function PwaProbe() {
  const {
    installMode,
    updateAvailable,
    requestInstall,
    applyUpdate,
    dismissUpdate
  } = usePwa();
  const [result, setResult] = useState("");

  return (
    <main>
      <output aria-label="Install mode">{installMode}</output>
      <output aria-label="Install result">{result}</output>
      <output aria-label="Update available">{String(updateAvailable)}</output>
      {installMode !== "installed" && (
        <button
          type="button"
          onClick={() => void requestInstall().then(setResult)}
        >
          Install
        </button>
      )}
      <button type="button" onClick={applyUpdate}>Apply update</button>
      <button type="button" onClick={dismissUpdate}>Dismiss update</button>
    </main>
  );
}

function renderPwa() {
  return render(
    <PwaProvider>
      <PwaProbe />
    </PwaProvider>
  );
}

function installBrowser({
  standalone = false,
  waiting = null
}: {
  standalone?: boolean;
  waiting?: ReturnType<typeof serviceWorker> | null;
} = {}) {
  const registration = Object.assign(new EventTarget(), {
    installing: null as ServiceWorker | null,
    waiting: waiting?.worker || null,
    update: vi.fn().mockResolvedValue(undefined)
  }) as unknown as EventTarget & ServiceWorkerRegistration & {
    waiting: ServiceWorker | null;
  };
  const container = Object.assign(new EventTarget(), {
    register: vi.fn().mockResolvedValue(registration)
  });
  Object.defineProperty(navigator, "serviceWorker", {
    configurable: true,
    value: container
  });
  vi.stubGlobal("matchMedia", vi.fn().mockImplementation(() => ({
    matches: standalone,
    media: "(display-mode: standalone)",
    onchange: null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn()
  })));
  return registration;
}

function serviceWorker() {
  const postMessage = vi.fn();
  const worker = Object.assign(new EventTarget(), {
    postMessage,
    state: "installed"
  }) as unknown as EventTarget & ServiceWorker;
  return { worker, postMessage };
}
