import type { ApiClient } from "../../api";
import type { AudioCallRealtimeEvent, Conversation } from "../../types";
import { CallPanel } from "./CallPanel";

/**
 * Audio-only compatibility surface retained for focused tests and downstream
 * embedders. The product workspace uses CallPanel so audio and video share one
 * active room and one lifecycle owner.
 */
export function AudioCallPanel({
  api,
  conversation,
  enabled,
  currentUserDisplayName,
  realtimeEvent
}: {
  api: ApiClient;
  conversation: Conversation;
  enabled: boolean;
  currentUserDisplayName: string;
  realtimeEvent?: AudioCallRealtimeEvent | null;
}) {
  return <CallPanel
    api={api}
    conversation={conversation}
    audioEnabled={enabled}
    videoEnabled={false}
    currentUserDisplayName={currentUserDisplayName}
    realtimeEvent={realtimeEvent}
    showVideoAction={false}
  />;
}
