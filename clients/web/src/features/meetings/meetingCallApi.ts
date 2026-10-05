import type { MeetingsApi } from "../../api/domains/meetings";
import type { CallMediaKind } from "../../types";
import type { CallApi } from "../calls/callContracts";

export interface MeetingLaunchContext {
  meetingId: string;
  occurrenceId: string;
}

/** Keep the existing media lobby while checking scheduled-meeting policy for every join. */
export function meetingCallApi(
  api: CallApi & Pick<MeetingsApi, "startMeeting">,
  context: MeetingLaunchContext,
  mediaKind: CallMediaKind
): CallApi {
  let linkedCallId: string | null = null;
  async function start(kind: CallMediaKind) {
    const response = await api.startMeeting(context.meetingId, context.occurrenceId, kind);
    linkedCallId = response.data.id;
    return response;
  }
  return new Proxy(api, {
    get(target, key) {
      if (key === "call" || key === "audioCall") return async (conversationId: string) => {
        const active = await target.call?.(conversationId);
        return linkedCallId && active?.id === linkedCallId ? active : null;
      };
      if (key === "startCall") return (_conversationId: string, kind: CallMediaKind) => start(kind);
      if (key === "joinCall") return () => start(mediaKind);
      if (key === "startAudioCall" || key === "joinAudioCall") return () => start("audio");
      // Preserve class methods and future call capabilities with their original receiver.
      const value: unknown = Reflect.get(target, key, target);
      return typeof value === "function" ? value.bind(target) : value;
    }
  });
}
