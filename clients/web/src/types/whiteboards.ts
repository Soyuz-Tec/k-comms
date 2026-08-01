export type WhiteboardElementData = Record<string, unknown> & {
  id: string;
  type: string;
  version: number;
  versionNonce: number;
};

export interface WhiteboardOperation {
  id: string;
  whiteboard_id: string;
  tenant_id: string;
  conversation_id: string;
  actor_user_id: string;
  client_operation_id: string;
  sequence: number;
  kind: "scene.update" | "board.clear";
  payload: {
    elements?: WhiteboardElementData[];
  };
  inserted_at: string;
}

export interface WhiteboardOperationPage {
  data: WhiteboardOperation[];
  page: {
    has_more: boolean;
    next_after_sequence: number;
  };
}

export interface WhiteboardPresenceEvent {
  user_id: string;
  device_id: string;
  pointer: { x: number; y: number; tool: "pointer" | "laser" };
  button: boolean;
  selected_element_ids: string[];
}
