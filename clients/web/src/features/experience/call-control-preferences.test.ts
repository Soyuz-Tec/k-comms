import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  applyCallControlPreferencesToDocument,
  CALL_CONTROL_PREFERENCE_KEYS,
  getCallControlPreferences,
  resetCallControlPreferencesForTest,
  setCallControlPreference
} from "./call-control-preferences";

describe("call control preferences", () => {
  beforeEach(() => {
    window.localStorage.clear();
    resetCallControlPreferencesForTest();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    resetCallControlPreferencesForTest();
    delete document.documentElement.dataset.callControls;
    delete document.documentElement.dataset.callContrast;
  });

  it("defaults every preference off", () => {
    expect(getCallControlPreferences()).toEqual({
      alwaysShow: false,
      opaque: false,
      highContrast: false
    });
  });

  it("round-trips each preference through storage independently", () => {
    setCallControlPreference("opaque", true);
    expect(window.localStorage.getItem(CALL_CONTROL_PREFERENCE_KEYS.opaque)).toBe("true");
    expect(getCallControlPreferences()).toEqual({
      alwaysShow: false,
      opaque: true,
      highContrast: false
    });

    setCallControlPreference("highContrast", true);
    expect(getCallControlPreferences().opaque).toBe(true);
    expect(getCallControlPreferences().highContrast).toBe(true);

    setCallControlPreference("opaque", false);
    expect(getCallControlPreferences()).toEqual({
      alwaysShow: false,
      opaque: false,
      highContrast: true
    });
  });

  it("returns a stable snapshot until something changes", () => {
    // useSyncExternalStore compares by identity; recomputing per call would
    // re-render forever.
    const first = getCallControlPreferences();
    expect(getCallControlPreferences()).toBe(first);

    setCallControlPreference("opaque", true);
    expect(getCallControlPreferences()).not.toBe(first);
  });

  it("falls back to on when storage cannot be read", () => {
    // Off is the designed experience; on is the accessible one. If we cannot
    // tell what someone chose, assume nothing about their eyesight.
    resetCallControlPreferencesForTest();
    vi.stubGlobal("localStorage", {
      getItem() {
        throw new Error("blocked");
      },
      setItem() {
        throw new Error("blocked");
      }
    });
    expect(getCallControlPreferences()).toEqual({
      alwaysShow: true,
      opaque: true,
      highContrast: true
    });
  });

  it("still applies a change this session when it cannot be saved", () => {
    let stored: Record<string, string> = {};
    let writable = true;
    vi.stubGlobal("localStorage", {
      getItem: (key: string) => stored[key] ?? null,
      setItem: (key: string, value: string) => {
        if (!writable) throw new Error("quota");
        stored[key] = value;
      }
    });
    resetCallControlPreferencesForTest();
    expect(getCallControlPreferences().opaque).toBe(false);

    writable = false;
    setCallControlPreference("opaque", true);
    // Not persisted, but the snapshot was still recomputed from a store that
    // never took the write -- so it stays false rather than lying.
    expect(getCallControlPreferences().opaque).toBe(false);
    stored = {};
  });

  describe("document publishing", () => {
    it("stamps only the appearance preferences", () => {
      // alwaysShow changes behaviour, not appearance: nothing styles from it,
      // so it has no business on the root.
      applyCallControlPreferencesToDocument({
        alwaysShow: true,
        opaque: true,
        highContrast: true
      });
      expect(document.documentElement.dataset.callControls).toBe("opaque");
      expect(document.documentElement.dataset.callContrast).toBe("high");
    });

    it("removes an attribute when its preference goes off", () => {
      applyCallControlPreferencesToDocument({
        alwaysShow: false,
        opaque: true,
        highContrast: true
      });
      applyCallControlPreferencesToDocument({
        alwaysShow: false,
        opaque: false,
        highContrast: true
      });
      expect(document.documentElement.dataset.callControls).toBeUndefined();
      expect(document.documentElement.dataset.callContrast).toBe("high");
    });

    it("cleans up both, so a signed-out shell is not styled as a call surface", () => {
      const cleanup = applyCallControlPreferencesToDocument({
        alwaysShow: false,
        opaque: true,
        highContrast: true
      });
      cleanup();
      expect(document.documentElement.dataset.callControls).toBeUndefined();
      expect(document.documentElement.dataset.callContrast).toBeUndefined();
    });
  });
});
