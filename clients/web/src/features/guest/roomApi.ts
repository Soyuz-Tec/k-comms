import type { ApiClient } from "../../api";
import type {
  Call,
  CallMediaKind,
  CallSessionResponse,
  Conversation,
  ConversationMembership,
  GuestAccountConversionResult,
  Message,
  MessagePage
} from "../../types";

export interface GuestRoomApi {
  conversation(): Promise<Conversation>;
  conversationMembers(): Promise<ConversationMembership[]>;
  messages(afterSequence?: number, limit?: number): Promise<MessagePage>;
  sendMessage(input: {
    client_message_id: string;
    body: string;
    attachment_ids: string[];
  }): Promise<Message>;
  markRead(sequence: number): Promise<void>;
  socketTicket(): Promise<{ ticket: string; expires_in: number }>;
  call(conversationId?: string): Promise<Call | null>;
  startCall(
    conversationId: string,
    mediaKind: CallMediaKind
  ): Promise<CallSessionResponse>;
  joinCall(
    conversationId: string,
    callId: string
  ): Promise<CallSessionResponse>;
  endCall(conversationId: string, callId: string): Promise<Call>;
  convertAccount?(input: {
    email: string;
    password: string;
    verification_code?: string;
    display_name?: string;
  }): Promise<GuestAccountConversionResult>;
  logout(): Promise<void>;
}

export class MemberRoomApi implements GuestRoomApi {
  constructor(
    private readonly api: ApiClient,
    private readonly conversationId: string
  ) {}

  conversation(): Promise<Conversation> {
    return this.api.conversation(this.conversationId);
  }

  conversationMembers(): Promise<ConversationMembership[]> {
    return this.api.conversationMembers(this.conversationId);
  }

  messages(afterSequence = 0, limit = 200): Promise<MessagePage> {
    return this.api.messages(this.conversationId, afterSequence, limit);
  }

  sendMessage(input: {
    client_message_id: string;
    body: string;
    attachment_ids: string[];
  }): Promise<Message> {
    return this.api.sendMessage(this.conversationId, input);
  }

  markRead(sequence: number): Promise<void> {
    return this.api.markRead(this.conversationId, sequence);
  }

  socketTicket(): Promise<{ ticket: string; expires_in: number }> {
    return this.api.socketTicket();
  }

  call(): Promise<Call | null> {
    return this.api.call(this.conversationId);
  }

  startCall(
    _conversationId: string,
    mediaKind: CallMediaKind
  ): Promise<CallSessionResponse> {
    return this.api.startCall(this.conversationId, mediaKind);
  }

  joinCall(
    _conversationId: string,
    callId: string
  ): Promise<CallSessionResponse> {
    return this.api.joinCall(this.conversationId, callId);
  }

  endCall(_conversationId: string, callId: string): Promise<Call> {
    return this.api.endCall(this.conversationId, callId);
  }

  logout(): Promise<void> {
    return Promise.resolve();
  }
}

export class DelegatingRoomApi implements GuestRoomApi {
  constructor(private delegate: GuestRoomApi) {}

  setDelegate(delegate: GuestRoomApi): void {
    this.delegate = delegate;
  }

  conversation(): Promise<Conversation> {
    return this.delegate.conversation();
  }

  conversationMembers(): Promise<ConversationMembership[]> {
    return this.delegate.conversationMembers();
  }

  messages(afterSequence = 0, limit = 200): Promise<MessagePage> {
    return this.delegate.messages(afterSequence, limit);
  }

  sendMessage(input: {
    client_message_id: string;
    body: string;
    attachment_ids: string[];
  }): Promise<Message> {
    return this.delegate.sendMessage(input);
  }

  markRead(sequence: number): Promise<void> {
    return this.delegate.markRead(sequence);
  }

  socketTicket(): Promise<{ ticket: string; expires_in: number }> {
    return this.delegate.socketTicket();
  }

  call(conversationId?: string): Promise<Call | null> {
    return this.delegate.call(conversationId);
  }

  startCall(
    conversationId: string,
    mediaKind: CallMediaKind
  ): Promise<CallSessionResponse> {
    return this.delegate.startCall(conversationId, mediaKind);
  }

  joinCall(
    conversationId: string,
    callId: string
  ): Promise<CallSessionResponse> {
    return this.delegate.joinCall(conversationId, callId);
  }

  endCall(conversationId: string, callId: string): Promise<Call> {
    return this.delegate.endCall(conversationId, callId);
  }

  convertAccount(input: {
    email: string;
    password: string;
    verification_code?: string;
    display_name?: string;
  }): Promise<GuestAccountConversionResult> {
    if (!this.delegate.convertAccount) {
      return Promise.reject(
        new Error("Account creation is not available for this room session.")
      );
    }
    return this.delegate.convertAccount(input);
  }

  logout(): Promise<void> {
    return this.delegate.logout();
  }
}
