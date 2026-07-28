import { afterEach, describe, expect, it, vi } from "vitest";
import {
  activateWaitingWorker,
  ensurePwaRegistration,
  pwaWorkerUrl,
  resetPwaRegistrationForTests
} from "./registration";

afterEach(() => {
  resetPwaRegistrationForTests();
  vi.unstubAllEnvs();
  Reflect.deleteProperty(navigator, "serviceWorker");
});

describe("PWA service-worker registration", () => {
  it("registers eagerly with a revisioned URL without requesting notification permission", async () => {
    vi.stubEnv("VITE_K_COMMS_RELEASE_REVISION", "release/a b");
    const registration = {} as ServiceWorkerRegistration;
    const register = vi.fn().mockResolvedValue(registration);
    const requestPermission = vi.fn();
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: { register }
    });
    vi.stubGlobal("Notification", { requestPermission });

    await expect(ensurePwaRegistration()).resolves.toBe(registration);
    await expect(ensurePwaRegistration()).resolves.toBe(registration);

    expect(pwaWorkerUrl()).toBe(
      "/app/k-comms-sw.js?revision=release%2Fa%20b"
    );
    expect(register).toHaveBeenCalledTimes(1);
    expect(register).toHaveBeenCalledWith(
      "/app/k-comms-sw.js?revision=release%2Fa%20b",
      {
        scope: "/app/",
        type: "module",
        updateViaCache: "none"
      }
    );
    expect(requestPermission).not.toHaveBeenCalled();
  });

  it("activates a waiting worker only after an explicit apply action", () => {
    const container = new EventTarget();
    const postMessage = vi.fn();
    const waiting = Object.assign(new EventTarget(), {
      postMessage,
      state: "installed"
    });
    const registration = {
      waiting
    } as unknown as ServiceWorkerRegistration;
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: container
    });
    const onControllerChange = vi.fn();

    expect(
      activateWaitingWorker(registration, onControllerChange)
    ).toBe(true);
    expect(postMessage).toHaveBeenCalledWith({ type: "SKIP_WAITING" });
    expect(onControllerChange).not.toHaveBeenCalled();

    container.dispatchEvent(new Event("controllerchange"));
    container.dispatchEvent(new Event("controllerchange"));
    expect(onControllerChange).toHaveBeenCalledTimes(1);
  });

  it("reloads an out-of-scope client when the waiting worker activates", () => {
    const container = new EventTarget();
    const waiting = Object.assign(new EventTarget(), {
      postMessage: vi.fn(),
      state: "installed"
    });
    const registration = {
      waiting
    } as unknown as ServiceWorkerRegistration;
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: container
    });
    const onActivated = vi.fn();

    expect(activateWaitingWorker(registration, onActivated)).toBe(true);
    waiting.state = "activated";
    waiting.dispatchEvent(new Event("statechange"));
    container.dispatchEvent(new Event("controllerchange"));

    expect(onActivated).toHaveBeenCalledTimes(1);
  });

  it("reloads when another tab already activated the snapshotted worker", () => {
    const container = new EventTarget();
    const waiting = Object.assign(new EventTarget(), {
      postMessage: vi.fn(),
      state: "activated"
    });
    const registration = {
      waiting
    } as unknown as ServiceWorkerRegistration;
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: container
    });
    const onActivated = vi.fn();

    expect(activateWaitingWorker(registration, onActivated)).toBe(false);
    expect(onActivated).toHaveBeenCalledTimes(1);
    expect(waiting.postMessage).not.toHaveBeenCalled();
  });

  it("reloads a stale tab when another tab already activated the update", () => {
    const container = new EventTarget();
    const registration = {
      waiting: null
    } as unknown as ServiceWorkerRegistration;
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: container
    });
    const onActivated = vi.fn();

    expect(activateWaitingWorker(registration, onActivated)).toBe(false);
    expect(onActivated).toHaveBeenCalledTimes(1);
  });
});
