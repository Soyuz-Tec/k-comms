let installed = false;
const streams = new Set<MediaStream>();
export function stopDesktopCapture(): void {
  for (const stream of streams) for (const track of stream.getTracks()) track.stop();
  streams.clear();
}
/** Covers the real browser APIs used by both LiveKit and direct audio. */
export function installDesktopMediaGuard(identity: () => string | null): void {
  if (installed || !navigator.mediaDevices) return;
  installed = true;
  const capture = async (request: () => Promise<MediaStream>) => {
    const current = identity();
    if (!current) throw new DOMException("A current desktop session is required", "NotAllowedError");
    const stream = await request();
    if (identity() !== current) {
      for (const track of stream.getTracks()) track.stop();
      throw new DOMException("The desktop session changed during capture", "AbortError");
    }
    streams.add(stream);
    for (const track of stream.getTracks()) track.addEventListener("ended", () => {
      if (stream.getTracks().every(value => value.readyState === "ended")) streams.delete(stream);
    }, { once: true });
    return stream;
  };
  const microphoneAndCamera = navigator.mediaDevices.getUserMedia?.bind(navigator.mediaDevices);
  const display = navigator.mediaDevices.getDisplayMedia?.bind(navigator.mediaDevices);
  if (microphoneAndCamera) navigator.mediaDevices.getUserMedia = constraints => capture(() => microphoneAndCamera(constraints));
  if (display) navigator.mediaDevices.getDisplayMedia = options => capture(() => display(options));
}
