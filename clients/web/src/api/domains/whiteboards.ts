import type {
  DataResponse,
  WhiteboardElementData,
  WhiteboardOperation,
  WhiteboardOperationPage
} from "../../types";
import type { ApiRequest } from "../contracts";

export function createWhiteboardsApi(request: ApiRequest) {
  return {
    operations(
      conversationId: string,
      afterSequence = 0,
      limit = 500
    ): Promise<WhiteboardOperationPage> {
      const query = new URLSearchParams({
        after_sequence: String(Math.max(0, afterSequence)),
        limit: String(Math.max(1, Math.min(limit, 500)))
      });

      return request(
        `/api/v1/conversations/${encodeURIComponent(conversationId)}/whiteboard/operations?${query.toString()}`
      );
    },

    appendSceneUpdate(
      conversationId: string,
      clientOperationId: string,
      baseSequence: number,
      elements: WhiteboardElementData[]
    ): Promise<WhiteboardOperation> {
      return request<DataResponse<WhiteboardOperation>>(
        `/api/v1/conversations/${encodeURIComponent(conversationId)}/whiteboard/operations`,
        {
          method: "POST",
          headers: { "Idempotency-Key": clientOperationId },
          body: JSON.stringify({
            kind: "scene.update",
            base_sequence: Math.max(0, baseSequence),
            payload: { elements }
          })
        }
      ).then((response) => response.data);
    },

    clearWhiteboard(
      conversationId: string,
      clientOperationId: string
    ): Promise<WhiteboardOperation> {
      return request<DataResponse<WhiteboardOperation>>(
        `/api/v1/conversations/${encodeURIComponent(conversationId)}/whiteboard/operations`,
        {
          method: "POST",
          headers: { "Idempotency-Key": clientOperationId },
          body: JSON.stringify({ kind: "board.clear", payload: {} })
        }
      ).then((response) => response.data);
    }
  };
}

export type WhiteboardsApi = ReturnType<typeof createWhiteboardsApi>;
