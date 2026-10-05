import { useEffect, useState } from "react";
import { RoomEvent, type Participant, type Room, type TranscriptionSegment } from "livekit-client";

export interface LiveCaption { id: string; text: string; speaker: string; final: boolean }
export function useLiveCaptions(room: Room | null, enabled: boolean) {
  const [captions, setCaptions] = useState<LiveCaption[]>([]);
  useEffect(() => {
    setCaptions([]);
    if (!room || !enabled) return;
    const received = (segments: TranscriptionSegment[], participant?: Participant) => {
      if (!Array.isArray(segments)) return;
      if (participant && participant !== room.localParticipant && !room.remoteParticipants.has(participant.identity)) return;
      setCaptions(current => {
        const next = new Map(current.map(caption => [caption.id, caption]));
        for (const segment of segments.slice(0, 50)) {
          if (typeof segment.id !== "string" || typeof segment.text !== "string") continue;
          const id = `${participant?.identity ?? "provider"}:${segment.id.slice(0, 200)}`;
          next.set(id, { id, text: segment.text.slice(0, 2_000), speaker: participant?.name || "Participant", final: segment.final });
        }
        return [...next.values()].slice(-100);
      });
    };
    room.on(RoomEvent.TranscriptionReceived, received);
    return () => { room.off(RoomEvent.TranscriptionReceived, received); };
  }, [enabled, room]);
  return captions;
}
