import type { Conversation, ConversationMembership, DataResponse, ListResponse, Message, MessagePage, MessageSearchOptions, MessageSearchPage, MessageThread, PublicChannelDiscoveryPage, PublicChannelMembershipResponse, RetainedSenderLabel } from "../../types";
import type { ApiRequest, CreateConversationInput, SendMessageInput } from "../contracts";

interface MessagingApiSupport {
  resolveSenderLabelBatches: (
    messageIds: string[],
    resolveBatch: (messageIds: string[]) => Promise<RetainedSenderLabel[]>
  ) => Promise<RetainedSenderLabel[]>;
}

export function createMessagingApi(request: ApiRequest, { resolveSenderLabelBatches }: MessagingApiSupport) {
  const api = {
    conversations(): Promise<Conversation[]> {
        return request<ListResponse<Conversation>>("/api/v1/conversations").then(
          (response) => response.data
        );
      },

    discoverPublicChannels(query = "", limit = 25, cursor?: string | null): Promise<PublicChannelDiscoveryPage> {
        const params = new URLSearchParams({ q: query, limit: String(limit) });
        if (cursor) params.set("cursor", cursor);
        return request(`/api/v1/channels/discover?${params.toString()}`);
      },

    joinPublicChannel(id: string): Promise<PublicChannelMembershipResponse> {
        return request(`/api/v1/channels/${encodeURIComponent(id)}/join`, { method: "POST" });
      },

    leavePublicChannel(id: string, version: number): Promise<PublicChannelMembershipResponse> {
        return request(`/api/v1/channels/${encodeURIComponent(id)}/membership`, {
          method: "DELETE",
          body: JSON.stringify({ version })
        });
      },

    conversation(id: string): Promise<Conversation> {
        return request<DataResponse<Conversation>>(
          `/api/v1/conversations/${encodeURIComponent(id)}`
        ).then((response) => response.data);
      },

    createConversation(input: CreateConversationInput): Promise<Conversation> {
        return request<DataResponse<Conversation>>("/api/v1/conversations", {
          method: "POST",
          body: JSON.stringify(input)
        }).then((response) => response.data);
      },

    updateConversation(id: string, input: { title?: string; visibility?: "private" | "tenant"; version: number }): Promise<Conversation> {
        return request<DataResponse<Conversation>>(`/api/v1/conversations/${encodeURIComponent(id)}`, {
          method: "PATCH",
          body: JSON.stringify(input)
        }).then((response) => response.data);
      },

    archiveConversation(id: string, version: number): Promise<Conversation> {
        return request<DataResponse<Conversation>>(`/api/v1/conversations/${encodeURIComponent(id)}/archive`, {
          method: "POST",
          body: JSON.stringify({ version })
        }).then((response) => response.data);
      },

    conversationMembers(conversationId: string): Promise<ConversationMembership[]> {
        return request<ListResponse<ConversationMembership>>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/members`
        ).then((response) => response.data);
      },

    addConversationMember(
        conversationId: string,
        userId: string,
        role: ConversationMembership["role"] = "member"
      ): Promise<{ id: string }> {
        return request<DataResponse<{ id: string }>>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/members`,
          { method: "POST", body: JSON.stringify({ user_id: userId, role }) }
        ).then((response) => response.data);
      },

    removeConversationMember(conversationId: string, userId: string, version: number): Promise<void> {
        return request(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/members/${encodeURIComponent(userId)}`,
          { method: "DELETE", body: JSON.stringify({ version }) }
        );
      },

    updateConversationMember(
        conversationId: string,
        userId: string,
        role: ConversationMembership["role"],
        version: number
      ): Promise<{ id: string; role: ConversationMembership["role"]; version: number }> {
        return request<DataResponse<{ id: string; role: ConversationMembership["role"]; version: number }>>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/members/${encodeURIComponent(userId)}`,
          { method: "PATCH", body: JSON.stringify({ role, version }) }
        ).then((response) => response.data);
      },

    messages(
        conversationId: string,
        afterSequence = 0,
        limit = 200,
        beforeSequence?: number
      ): Promise<MessagePage> {
        const query = new URLSearchParams({
          after_sequence: String(afterSequence),
          limit: String(limit),
          include: "sender_labels"
        });
        if (beforeSequence !== undefined) query.set("before_sequence", String(beforeSequence));
        return request<MessagePage>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages?${query.toString()}`
        );
      },

    messageSenderLabels(
        conversationId: string,
        messageIds: string[]
      ): Promise<RetainedSenderLabel[]> {
        return resolveSenderLabelBatches(messageIds, (batch) =>
          request<DataResponse<RetainedSenderLabel[]>>(
            `/api/v1/conversations/${encodeURIComponent(conversationId)}/message-sender-labels`,
            {
              method: "POST",
              body: JSON.stringify({ message_ids: batch })
            }
          ).then((response) => response.data)
        );
      },

    messageThread(
        conversationId: string,
        messageId: string,
        beforeSequence?: number,
        limit = 50
      ): Promise<MessageThread> {
        const query = new URLSearchParams({
          limit: String(Math.max(1, Math.min(limit, 100))),
          include: "sender_labels"
        });
        if (beforeSequence !== undefined) query.set("before_sequence", String(beforeSequence));
        return request(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(messageId)}/thread?${query.toString()}`
        );
      },

    sendMessage(conversationId: string, input: SendMessageInput): Promise<Message> {
        const { client_message_id: idempotencyKey, ...body } = input;
        return request<DataResponse<Message>>(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages`,
          {
            method: "POST",
            headers: { "Idempotency-Key": idempotencyKey },
            body: JSON.stringify(body)
          }
        ).then((response) => response.data);
      },

    editMessage(messageId: string, body: string): Promise<Message> {
        return request<DataResponse<Message>>(`/api/v1/messages/${encodeURIComponent(messageId)}`, {
          method: "PATCH",
          body: JSON.stringify({ body })
        }).then((response) => response.data);
      },

    deleteMessage(messageId: string): Promise<Message> {
        return request<DataResponse<Message>>(`/api/v1/messages/${encodeURIComponent(messageId)}`, {
          method: "DELETE"
        }).then((response) => response.data);
      },

    searchMessages(query: string, limit = 50): Promise<Message[]> {
        const params = new URLSearchParams({ q: query, limit: String(limit) });
        return request<ListResponse<Message>>(`/api/v1/search?${params.toString()}`).then(
          (response) => response.data
        );
      },

    searchMessagePage(query: string, options: MessageSearchOptions = {}): Promise<MessageSearchPage> {
        const params = new URLSearchParams({
          q: query,
          limit: String(Math.max(1, Math.min(options.limit ?? 50, 200))),
          include: "sender_labels"
        });
        if (options.cursor) params.set("cursor", options.cursor);
        if (options.conversation_id) params.set("conversation_id", options.conversation_id);
        if (options.sender_user_id) params.set("sender_user_id", options.sender_user_id);
        if (options.after) params.set("after", options.after);
        if (options.before) params.set("before", options.before);
        return request<MessageSearchPage>(`/api/v1/search?${params.toString()}`);
      },

    addReaction(conversationId: string, messageId: string, emoji: string): Promise<void> {
        return request(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(messageId)}/reactions`,
          { method: "POST", body: JSON.stringify({ emoji }) }
        );
      },

    removeReaction(conversationId: string, messageId: string, emoji: string): Promise<void> {
        return request(
          `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(messageId)}/reactions/${encodeURIComponent(emoji)}`,
          { method: "DELETE" }
        );
      },

    markRead(conversationId: string, sequence: number): Promise<void> {
        return request(`/api/v1/conversations/${encodeURIComponent(conversationId)}/read-cursor`, {
          method: "PUT",
          body: JSON.stringify({ sequence })
        });
      }
  };
  return api;
}

export type MessagingApi = ReturnType<typeof createMessagingApi>;
