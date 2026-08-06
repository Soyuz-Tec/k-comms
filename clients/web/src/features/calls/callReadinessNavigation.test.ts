import { describe, expect, it } from "vitest";
import {
  callReadinessGuestUrl,
  callReadinessHostPath,
  clearCallReadinessSearch,
  safeCallReadinessMode
} from "./callReadinessNavigation";

describe("call readiness navigation", () => {
  it("adds readiness parameters without exposing or changing the guest secret", () => {
    const value = callReadinessGuestUrl(
      "https://comms.example.test/join?existing=1#guest=secret-value"
    );
    const url = new URL(value);

    expect(url.searchParams.get("existing")).toBe("1");
    expect(url.searchParams.get("call")).toBe("audio");
    expect(url.searchParams.get("call_readiness")).toBe("office");
    expect(url.hash).toBe("#guest=secret-value");
  });

  it("builds a host route and accepts only the supported mode", () => {
    expect(callReadinessHostPath("conversation 1")).toBe(
      "/app/?conversation=conversation+1&call=audio&call_readiness=office"
    );
    expect(safeCallReadinessMode("office")).toBe("office");
    expect(safeCallReadinessMode("relay-debug")).toBeNull();
  });

  it("removes one-shot launch parameters without changing other navigation", () => {
    const result = clearCallReadinessSearch(
      new URLSearchParams("conversation=conversation-1&call=audio&call_readiness=office&message=message-1")
    );

    expect(result.toString()).toBe("conversation=conversation-1&message=message-1");
  });
});
