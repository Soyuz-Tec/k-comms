export interface CallAvailability {
  allowAudio: boolean;
  allowVideo: boolean;
  audioAvailable: boolean;
  videoAvailable: boolean;
}

export function callAvailabilityGuidance({
  allowAudio,
  allowVideo,
  audioAvailable,
  videoAvailable
}: CallAvailability): string | null {
  const audioReady = allowAudio && audioAvailable;
  const videoReady = allowVideo && videoAvailable;

  if (audioReady && videoReady) return null;
  if (!allowAudio && !allowVideo) {
    return "Calling is disabled by workspace policy. Keep messaging or ask a workspace administrator.";
  }
  if (!audioReady && !videoReady) {
    if (allowAudio && allowVideo) {
      return "Calling is temporarily unavailable. Keep messaging and refresh call availability from Calls.";
    }
    const audioReason = allowAudio
      ? "audio is temporarily unavailable"
      : "audio is disabled by workspace policy";
    const videoReason = allowVideo
      ? "video is temporarily unavailable"
      : "video is disabled by workspace policy";
    return `Calling is unavailable: ${audioReason} and ${videoReason}. Keep messaging and refresh call availability from Calls.`;
  }
  if (!audioReady) {
    return allowAudio
      ? "Audio calling is temporarily unavailable. Video calling remains available."
      : "Audio calling is disabled by workspace policy. Video calling remains available.";
  }
  return allowVideo
    ? "Video calling is temporarily unavailable. Audio calling remains available."
    : "Video calling is disabled by workspace policy. Audio calling remains available.";
}
