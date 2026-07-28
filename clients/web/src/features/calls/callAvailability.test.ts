import { describe, expect, it } from "vitest";
import { callAvailabilityGuidance } from "./callAvailability";

describe("callAvailabilityGuidance", () => {
  it("stays silent when both call media are ready", () => {
    expect(callAvailabilityGuidance({
      allowAudio: true,
      allowVideo: true,
      audioAvailable: true,
      videoAvailable: true
    })).toBeNull();
  });

  it("distinguishes workspace policy from provider availability", () => {
    expect(callAvailabilityGuidance({
      allowAudio: false,
      allowVideo: false,
      audioAvailable: true,
      videoAvailable: true
    })).toBe(
      "Calling is disabled by workspace policy. Keep messaging or ask a workspace administrator."
    );
    expect(callAvailabilityGuidance({
      allowAudio: true,
      allowVideo: true,
      audioAvailable: false,
      videoAvailable: false
    })).toBe(
      "Calling is temporarily unavailable. Keep messaging and refresh call availability from Calls."
    );
  });

  it("names one unavailable medium and confirms the working alternative", () => {
    expect(callAvailabilityGuidance({
      allowAudio: true,
      allowVideo: true,
      audioAvailable: false,
      videoAvailable: true
    })).toBe(
      "Audio calling is temporarily unavailable. Video calling remains available."
    );
    expect(callAvailabilityGuidance({
      allowAudio: true,
      allowVideo: false,
      audioAvailable: true,
      videoAvailable: true
    })).toBe(
      "Video calling is disabled by workspace policy. Audio calling remains available."
    );
  });

  it("explains mixed policy and runtime blockers", () => {
    expect(callAvailabilityGuidance({
      allowAudio: false,
      allowVideo: true,
      audioAvailable: true,
      videoAvailable: false
    })).toBe(
      "Calling is unavailable: audio is disabled by workspace policy and video is temporarily unavailable. Keep messaging and refresh call availability from Calls."
    );
  });
});
