import { describe, expect, it } from "vitest";
import { authenticationReturnTarget, guestContinuationState, safeMemberReturnTarget } from "./authNavigation";

describe("authentication navigation", () => {
  it("preserves known screens and their non-secret deep-link fields", () => {
    for (const path of ["/app/files?conversation=room&file=file-1", "/app/directory?q=Grace", "/app/whiteboard?conversation=room&focus_elements=shape-1", "/app/calls/phone", "/app/you?section=security", "/app/settings?section=security#account", "/app/meetings?meeting=meeting-1&occurrence=occurrence-1", "/app/saved", "/app/?search=content&query=handoff", "/app/?conversation=room&compose=attachment"]) {
      expect(authenticationReturnTarget("", { returnTo: path })).toBe(path);
    }
  });
  it("rejects external, normalized, encoded and unsupported destinations", () => {
    for (const path of ["https://evil.test/app/files", "//evil.test/app/files", "/\\evil.test", "/app/../ops", "/app/%66iles", "/sign-in", "/api/v1/sessions", "/app/files\n"]) {
      expect(safeMemberReturnTarget(path)).toBeNull();
      expect(authenticationReturnTarget(`?return_to=${encodeURIComponent(path)}`)).toBe("/app/");
    }
  });
  it("removes credentials and unsafe fragments from otherwise valid return targets", () => {
    expect(safeMemberReturnTarget("/app/files?file=file-1&guest=secret&invitation_token=secret&token=secret#guest=secret")).toBe("/app/files?file=file-1");
    expect(authenticationReturnTarget("?conversation=room&message=message&invitation_token=secret")).toBe("/app/?conversation=room&message=message");
    expect(safeMemberReturnTarget("/app/meetings?meeting=meeting-1&code=proof&state=oidc-state&challenge_token=challenge")).toBe("/app/meetings?meeting=meeting-1");
    expect(safeMemberReturnTarget("/app/artifacts?conversation=room&call=call-1&artifact=artifact-1&access_token=secret")).toBe("/app/artifacts?conversation=room&call=call-1&artifact=artifact-1");
  });
  it("keeps guest continuation only in validated navigation state", () => {
    expect(authenticationReturnTarget("", { returnTo: "/join", guestToken: "opaque-room-token" })).toBe("/join");
    expect(guestContinuationState({ returnTo: "/join", guestToken: "opaque-room-token" })).toEqual({ returnTo: "/join", guestToken: "opaque-room-token" });
    expect(guestContinuationState({ returnTo: "https://evil.test", guestToken: "secret" })).toBeUndefined();
    expect(guestContinuationState({ returnTo: "/join", guestToken: "bad&token" })).toEqual({ returnTo: "/join" });
    expect(authenticationReturnTarget("?return_to=%2Fjoin%23guest%3Dsecret")).toBe("/app/");
  });
});
