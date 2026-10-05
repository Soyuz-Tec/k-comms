import { afterEach, beforeEach, expect, it, vi } from "vitest";
beforeEach(() => vi.resetModules()); afterEach(() => vi.unstubAllGlobals());
function stream() { const track = { stop: vi.fn(), addEventListener: vi.fn(), readyState: "live" }; return { track, media: { getTracks: () => [track] } as unknown as MediaStream }; }
it("stops real API streams on logout and refuses a late permission/capture result", async () => {
  const captured = stream(); let resolve: (stream: MediaStream) => void = () => {}; let identity: string | null = "current";
  const mediaDevices = { getUserMedia: vi.fn(async () => captured.media), getDisplayMedia: vi.fn(() => new Promise<MediaStream>(done => { resolve = done; })) };
  vi.stubGlobal("navigator", { mediaDevices }); const { installDesktopMediaGuard, stopDesktopCapture } = await import("./media"); installDesktopMediaGuard(() => identity);
  await mediaDevices.getUserMedia(); const pending = mediaDevices.getDisplayMedia(); identity = null; stopDesktopCapture(); expect(captured.track.stop).toHaveBeenCalled(); const late = stream(); resolve(late.media); await expect(pending).rejects.toMatchObject({ name: "AbortError" }); expect(late.track.stop).toHaveBeenCalled(); await expect(mediaDevices.getUserMedia()).rejects.toMatchObject({ name: "NotAllowedError" });
});
it("delegates current-session constraints to the existing browser media API", async () => {
  const captured = stream(); const original = vi.fn<MediaDevices["getUserMedia"]>(async () => captured.media); const mediaDevices = { getUserMedia: original };
  vi.stubGlobal("navigator", { mediaDevices }); const { installDesktopMediaGuard } = await import("./media"); installDesktopMediaGuard(() => "same-user-device");
  const constraints = { audio: { echoCancellation: true }, video: false }; expect(await mediaDevices.getUserMedia(constraints)).toBe(captured.media); expect(original).toHaveBeenCalledWith(constraints); expect(captured.track.stop).not.toHaveBeenCalled();
});
