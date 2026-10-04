import { useCallback, useEffect, useRef, useState } from "react";

/** A local ringtone uses no microphone and includes no caller data. */
export function usePhoneRingtone(ringing: boolean) {
  const context = useRef<AudioContext | null>(null);
  const [blocked, setBlocked] = useState(false);
  const [muted, setMuted] = useState(false);

  const pulse = useCallback(() => {
    const audio = context.current;
    if (!audio || audio.state !== "running") { setBlocked(true); return; }
    setBlocked(false);
    for (const delay of [0, .35]) {
      const oscillator = audio.createOscillator();
      const gain = audio.createGain();
      const start = audio.currentTime + delay;
      oscillator.frequency.value = 440;
      gain.gain.setValueAtTime(0, start);
      gain.gain.linearRampToValueAtTime(.08, start + .02);
      gain.gain.linearRampToValueAtTime(0, start + .25);
      oscillator.connect(gain);
      gain.connect(audio.destination);
      oscillator.start(start);
      oscillator.stop(start + .3);
      oscillator.onended = () => { oscillator.disconnect(); gain.disconnect(); };
    }
  }, []);

  useEffect(() => {
    if (!ringing || muted) return;
    if (typeof AudioContext === "undefined") { setBlocked(true); return; }
    try { context.current = new AudioContext(); }
    catch { setBlocked(true); return; }
    pulse();
    const timer = window.setInterval(pulse, 2_000);
    return () => {
      window.clearInterval(timer);
      void context.current?.close().catch(() => undefined);
      context.current = null;
    };
  }, [ringing, muted, pulse]);

  async function enable() {
    if (!context.current) return;
    try { await context.current.resume(); pulse(); }
    catch { setBlocked(true); }
  }

  return { blocked, muted, enable, toggleMuted: () => setMuted((value) => !value) };
}
