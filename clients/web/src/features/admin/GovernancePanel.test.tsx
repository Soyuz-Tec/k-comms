import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { StepUpProvider } from "../../app/step-up";
import type { Conversation, LegalHold, Message, RetentionPolicy, User } from "../../types";
import { GovernancePanel } from "./GovernancePanel";

vi.mock("../../app/session", () => ({ useSession: () => ({ api: { stepUp: vi.fn() } }) }));

const activeUser: User = {
  id: "user-active",
  tenant_id: "tenant-1",
  display_name: "Alex Active",
  email: "alex@example.test",
  role: "member",
  status: "active"
};

const deletedUser: User = {
  ...activeUser,
  id: "user-deleted",
  display_name: "Dana Deleted",
  status: "deleted"
};

const activeConversation: Conversation = {
  id: "conversation-active",
  tenant_id: "tenant-1",
  kind: "channel",
  title: "Release planning",
  visibility: "private",
  latest_sequence: 7,
  inserted_at: "2026-07-12T09:00:00Z",
  updated_at: "2026-07-12T10:00:00Z"
};

const archivedConversation: Conversation = {
  ...activeConversation,
  id: "conversation-archived",
  title: "Archived project",
  archived_at: "2026-07-12T10:00:00Z"
};

function holdFor(input: {
  name: string;
  reason: string;
  scope_type: "tenant" | "user" | "conversation";
  target_id?: string;
}): LegalHold {
  return {
    id: `hold-${input.scope_type}`,
    created_by_user_id: "owner-1",
    name: input.name,
    reason: input.reason,
    scope_type: input.scope_type,
    subject_user_id: input.scope_type === "user" ? input.target_id : null,
    conversation_id: input.scope_type === "conversation" ? input.target_id : null,
    status: "active",
    starts_at: "2026-07-12T10:00:00Z",
    version: 1,
    inserted_at: "2026-07-12T10:00:00Z"
  };
}

function apiFixture(overrides: Partial<ApiClient> = {}): ApiClient {
  return {
    retentionPolicies: vi.fn().mockResolvedValue([]),
    legalHolds: vi.fn().mockResolvedValue([]),
    deletionRequests: vi.fn().mockResolvedValue([]),
    ...overrides
  } as unknown as ApiClient;
}

describe("GovernancePanel target selection", () => {
  it("reviews a retention-policy transition and submits its audited reason", async () => {
    const policy: RetentionPolicy = {
      id: "policy-1",
      name: "Standard retention",
      scope_type: "tenant",
      retention_days: 365,
      delete_attachments: true,
      status: "active",
      version: 1,
      inserted_at: "2026-07-12T10:00:00Z",
      updated_at: "2026-07-12T10:00:00Z"
    };
    const updateRetentionPolicy = vi.fn().mockResolvedValue({ ...policy, status: "disabled", version: 2 });
    const api = apiFixture({
      retentionPolicies: vi.fn().mockResolvedValue([policy]),
      updateRetentionPolicy
    } as Partial<ApiClient>);
    const user = userEvent.setup();
    render(<StepUpProvider><GovernancePanel api={api} users={[]} conversations={[]} /></StepUpProvider>);

    await user.click(await screen.findByRole("button", { name: "Disable" }));
    expect(screen.getByRole("alertdialog", { name: "Disable retention policy?" })).toHaveTextContent("Standard retention");
    await user.type(screen.getByRole("textbox", { name: "Reason for this change" }), "Policy under review");
    await user.click(screen.getByRole("button", { name: "Disable policy" }));

    await waitFor(() => expect(updateRetentionPolicy).toHaveBeenCalledWith("policy-1", {
      status: "disabled",
      version: 1,
      reason: "Policy under review"
    }));
  });

  it("creates user and conversation holds using human-readable active targets", async () => {
    const createLegalHold = vi.fn().mockImplementation((input) => Promise.resolve(holdFor(input)));
    const api = apiFixture({ createLegalHold } as Partial<ApiClient>);
    const user = userEvent.setup();
    render(<StepUpProvider><GovernancePanel api={api} users={[activeUser, deletedUser]} conversations={[activeConversation, archivedConversation]} /></StepUpProvider>);

    const section = screen.getByRole("heading", { name: "Legal holds" }).closest("section");
    expect(section).not.toBeNull();
    const controls = within(section as HTMLElement);

    await user.selectOptions(controls.getByLabelText("Hold scope"), "user");
    const userTarget = controls.getByLabelText("Hold user");
    expect(within(userTarget).getByRole("option", { name: "Alex Active" })).toBeVisible();
    expect(within(userTarget).queryByRole("option", { name: "Dana Deleted" })).not.toBeInTheDocument();
    await user.type(controls.getByLabelText("Hold name"), "Person preservation");
    await user.selectOptions(userTarget, activeUser.id);
    await user.type(controls.getByLabelText("Reason"), "Active investigation");
    await user.click(controls.getByRole("button", { name: "Create legal hold" }));
    await waitFor(() => expect(createLegalHold).toHaveBeenCalledWith({
      name: "Person preservation",
      reason: "Active investigation",
      scope_type: "user",
      target_id: activeUser.id
    }));
    await waitFor(() => {
      expect(controls.getByLabelText("Hold scope")).toHaveValue("tenant");
      expect(controls.getByLabelText("Hold name")).toHaveValue("");
      expect(controls.getByLabelText("Reason")).toHaveValue("");
    });

    await user.selectOptions(controls.getByLabelText("Hold scope"), "conversation");
    const conversationTarget = controls.getByLabelText("Hold conversation");
    expect(within(conversationTarget).getByRole("option", { name: "Release planning" })).toBeVisible();
    expect(within(conversationTarget).queryByRole("option", { name: "Archived project" })).not.toBeInTheDocument();
    await user.clear(controls.getByLabelText("Hold name"));
    await user.clear(controls.getByLabelText("Reason"));
    await user.type(controls.getByLabelText("Hold name"), "Channel preservation");
    await user.selectOptions(conversationTarget, activeConversation.id);
    await user.type(controls.getByLabelText("Reason"), "Regulatory request");
    await user.click(controls.getByRole("button", { name: "Create legal hold" }));
    await waitFor(() => expect(createLegalHold).toHaveBeenLastCalledWith({
      name: "Channel preservation",
      reason: "Regulatory request",
      scope_type: "conversation",
      target_id: activeConversation.id
    }));
  });

  it("selects user, conversation, and active message deletion targets without raw UUID entry", async () => {
    const activeMessage: Message = {
      id: "message-active",
      tenant_id: "tenant-1",
      conversation_id: activeConversation.id,
      sender_user_id: activeUser.id,
      sender_device_id: "device-1",
      client_message_id: "client-1",
      conversation_sequence: 7,
      body: "Please preserve this release note",
      metadata: {},
      status: "active",
      inserted_at: "2026-07-12T10:00:00Z",
      attachments: [],
      reactions: []
    };
    const messages = vi.fn().mockResolvedValue({
      data: [activeMessage, { ...activeMessage, id: "message-deleted", status: "deleted" }],
      page: { has_more: false, next_before_sequence: null }
    });
    const createDeletionRequest = vi.fn().mockResolvedValue({
      id: "deletion-1",
      requested_by_user_id: "owner-1",
      message_id: activeMessage.id,
      target_type: "message",
      reason: "Requested erasure",
      status: "pending",
      version: 1,
      inserted_at: "2026-07-12T10:00:00Z"
    });
    const api = apiFixture({ messages, createDeletionRequest } as Partial<ApiClient>);
    const user = userEvent.setup();
    render(<StepUpProvider><GovernancePanel api={api} users={[activeUser, deletedUser]} conversations={[activeConversation, archivedConversation]} /></StepUpProvider>);

    const section = screen.getByRole("heading", { name: "Deletion requests" }).closest("section");
    expect(section).not.toBeNull();
    const controls = within(section as HTMLElement);
    const userTarget = controls.getByLabelText("Deletion user");
    expect(within(userTarget).getByRole("option", { name: "Alex Active" })).toBeVisible();
    expect(within(userTarget).queryByRole("option", { name: "Dana Deleted" })).not.toBeInTheDocument();

    await user.selectOptions(controls.getByLabelText("Target type"), "conversation");
    const conversationTarget = controls.getByLabelText("Deletion conversation");
    expect(within(conversationTarget).getByRole("option", { name: "Release planning" })).toBeVisible();
    expect(within(conversationTarget).queryByRole("option", { name: "Archived project" })).not.toBeInTheDocument();

    await user.selectOptions(controls.getByLabelText("Target type"), "message");
    const messageConversation = controls.getByLabelText("Message conversation");
    expect(within(messageConversation).queryByRole("option", { name: "Archived project" })).not.toBeInTheDocument();
    await user.selectOptions(messageConversation, activeConversation.id);
    await waitFor(() => expect(messages).toHaveBeenCalledWith(activeConversation.id, 0, 200));
    const messageTarget = controls.getByLabelText("Deletion message");
    expect(await within(messageTarget).findByRole("option", { name: /Please preserve this release note/ })).toBeVisible();
    expect(within(messageTarget).queryByRole("option", { name: /message-deleted/ })).not.toBeInTheDocument();
    await user.selectOptions(messageTarget, activeMessage.id);
    await user.type(controls.getByLabelText("Reason"), "Requested erasure");
    await user.click(controls.getByRole("button", { name: "Request deletion" }));
    await waitFor(() => expect(createDeletionRequest).toHaveBeenCalledWith({
      target_type: "message",
      target_id: activeMessage.id,
      reason: "Requested erasure"
    }));
  });
});
