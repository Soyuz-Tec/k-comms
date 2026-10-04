import { afterEach, describe, expect, it, vi } from "vitest";
import {
  buildGuestJoinUrl,
  copyGuestUrl,
  guestTokenFromFragment,
  guestJoinTargetFromInput,
  scrubGuestTokenFragment,
  shareGuestUrl
} from "./guestLink";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("guest link handling", () => {
  it("accepts this deployment's full or relative invite without changing its bearer", () => {
    expect(guestJoinTargetFromInput("https://comms.example.test/join#guest=room-token", "https://comms.example.test")).toBe("/join#guest=room-token");
    expect(guestJoinTargetFromInput("/join/?call=audio&call_readiness=office#guest=room-token", "https://comms.example.test")).toBe("/join/?call=audio&call_readiness=office#guest=room-token");
  });

  it("rejects outside origins, unsafe schemes, credential queries and ambiguous links", () => {
    for (const value of ["https://other.test/join#guest=secret", "//other.test/join#guest=secret", "javascript:alert(1)", "/join?guest=secret", "/sign-in#invitation_token=secret", "/join#guest=one&guest=two", "/join#guest=one&token=two", "/join#guest=bad%20token", "https://name:password@comms.example.test/join#guest=secret", "/join?token=secret#guest=one", "/join?redirect=https://other.test#guest=one"]) {
      expect(guestJoinTargetFromInput(value, "https://comms.example.test")).toBeNull();
    }
  });
  it("preserves the exact token through URL encoding", () => {
    const token = "guest+token/with?reserved=&characters";
    const url = buildGuestJoinUrl(token, "https://comms.example.test");
    const parsed = new URL(url);

    expect(parsed.pathname).toBe("/join");
    expect(new URLSearchParams(parsed.hash.slice(1)).get("guest")).toBe(token);
  });

  it("reads the fragment token without mutating browser history", () => {
    const location = {
      hash: "#guest=single-use-secret",
      pathname: "/join",
      search: "?from=qr"
    } as Location;

    expect(guestTokenFromFragment(location)).toBe("single-use-secret");
    expect(location.hash).toBe("#guest=single-use-secret");
  });

  it("scrubs the fragment token from browser history", () => {
    const replaceState = vi.fn();
    const location = {
      hash: "#guest=single-use-secret",
      pathname: "/join",
      search: "?from=qr"
    } as Location;
    const history = { state: { preserved: true }, replaceState } as unknown as History;

    scrubGuestTokenFragment(location, history);

    expect(replaceState).toHaveBeenCalledWith(
      { preserved: true },
      "",
      "/join?from=qr"
    );
  });

  it("does not retain a token for a later fragmentless read", () => {
    expect(guestTokenFromFragment({
      hash: "#guest=strict-mode-secret",
      pathname: "/join",
      search: ""
    } as Location)).toBe("strict-mode-secret");
    expect(guestTokenFromFragment({
      hash: "",
      pathname: "/join",
      search: ""
    } as Location)).toBeNull();
  });

  it("copies the exact URL through the Clipboard API", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText }
    });
    const url = "https://comms.example.test/join#guest=encoded-token";

    await copyGuestUrl(url);

    expect(writeText).toHaveBeenCalledWith(url);
  });

  it("uses the same URL for native sharing", async () => {
    const share = vi.fn().mockResolvedValue(undefined);
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "share", {
      configurable: true,
      value: share
    });
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText }
    });
    const url = "https://comms.example.test/join#guest=one-token";

    await expect(shareGuestUrl(url)).resolves.toBe("shared");

    expect(share).toHaveBeenCalledWith(expect.objectContaining({ url }));
    expect(writeText).not.toHaveBeenCalled();
  });

  it("falls back to copying when native sharing is unavailable", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "share", {
      configurable: true,
      value: undefined
    });
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText }
    });
    const url = "https://comms.example.test/join#guest=fallback-token";

    await expect(shareGuestUrl(url)).resolves.toBe("copied");
    expect(writeText).toHaveBeenCalledWith(url);
  });
});
