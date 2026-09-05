import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import { StepUpCancelledError, StepUpProvider } from "../../app/step-up";
import type { Conversation, DeletionRequest, LegalHold, Message, RetentionPolicy, User } from "../../types";
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
  counterpart_user_id: null,
  counterpart_display_name: null,
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

function policyFixture(overrides: Partial<RetentionPolicy> = {}): RetentionPolicy {
  return {
    id: "policy-1",
    name: "Standard retention",
    scope_type: "tenant",
    retention_days: 365,
    delete_attachments: false,
    status: "active",
    version: 1,
    inserted_at: "2026-07-12T10:00:00Z",
    updated_at: "2026-07-12T10:00:00Z",
    ...overrides
  };
}

function deletionFixture(overrides: Partial<DeletionRequest> = {}): DeletionRequest {
  return {
    id: "deletion-1",
    requested_by_user_id: "owner-1",
    subject_user_id: activeUser.id,
    target_type: "user",
    reason: "Requested erasure",
    status: "pending",
    evidence: {},
    version: 1,
    inserted_at: "2026-07-12T10:00:00Z",
    updated_at: "2026-07-12T10:00:00Z",
    ...overrides
  };
}

describe("GovernancePanel consequence review", () => {
  it("requires review with attachment deletion off and preserves the policy draft on cancel", async () => {
    const createRetentionPolicy = vi.fn().mockResolvedValue(policyFixture());
    const api = apiFixture({ createRetentionPolicy });
    const user = userEvent.setup();
    render(<StepUpProvider><GovernancePanel api={api} users={[]} conversations={[]} /></StepUpProvider>);

    expect(screen.getByRole("checkbox", { name: "Delete attachments" })).not.toBeChecked();
    await user.type(screen.getByLabelText("Policy name"), "Release archive");
    await user.type(screen.getByLabelText("Retention days"), "90");
    await user.click(screen.getByRole("button", { name: "Review policy" }));

    const dialog = screen.getByRole("alertdialog", { name: "Create and activate retention policy?" });
    expect(dialog).toHaveTextContent("Release archive · Entire workspace · Retain messages for 90 days.");
    expect(dialog).toHaveTextContent("becomes active immediately and queues a retention scan");
    expect(dialog).toHaveTextContent("Eligible messages older than 90 days can be queued for deletion without another approval");
    expect(dialog).toHaveTextContent("Attachments are retained by this policy");
    expect(dialog).toHaveTextContent("Active legal holds still apply");
    expect(within(dialog).queryByRole("textbox", { name: "Reason for this change" })).not.toBeInTheDocument();
    expect(createRetentionPolicy).not.toHaveBeenCalled();

    await user.click(within(dialog).getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(screen.getByLabelText("Policy name")).toHaveValue("Release archive");
    expect(screen.getByLabelText("Retention days")).toHaveValue(90);
    expect(createRetentionPolicy).not.toHaveBeenCalled();
  });

  it.each([false, true])("creates only the explicitly confirmed policy with delete_attachments=%s", async (deleteAttachments) => {
    const createRetentionPolicy = vi.fn().mockResolvedValue(policyFixture({ name: "Release archive", retention_days: 90, delete_attachments: deleteAttachments }));
    const api = apiFixture({ createRetentionPolicy });
    const user = userEvent.setup();
    render(<StepUpProvider><GovernancePanel api={api} users={[]} conversations={[]} /></StepUpProvider>);

    await user.type(screen.getByLabelText("Policy name"), "Release archive");
    await user.type(screen.getByLabelText("Retention days"), "90");
    if (deleteAttachments) await user.click(screen.getByRole("checkbox", { name: "Delete attachments" }));
    await user.click(screen.getByRole("button", { name: "Review policy" }));
    const dialog = screen.getByRole("alertdialog", { name: "Create and activate retention policy?" });
    expect(dialog).toHaveTextContent(deleteAttachments ? "Attachments belonging to eligible messages are included in deletion" : "Attachments are retained by this policy");
    expect(createRetentionPolicy).not.toHaveBeenCalled();

    await user.click(within(dialog).getByRole("button", { name: "Create and activate policy" }));
    await waitFor(() => expect(createRetentionPolicy).toHaveBeenCalledExactlyOnceWith({ name: "Release archive", retention_days: 90, delete_attachments: deleteAttachments }));
    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument());
    expect(screen.getByLabelText("Policy name")).toHaveValue("");
    expect(screen.getByRole("checkbox", { name: "Delete attachments" })).not.toBeChecked();
  });

  it("retains policy review and draft if identity verification is cancelled", async () => {
    const createRetentionPolicy = vi.fn().mockRejectedValue(new StepUpCancelledError());
    const api = apiFixture({ createRetentionPolicy });
    const user = userEvent.setup();
    render(<StepUpProvider><GovernancePanel api={api} users={[]} conversations={[]} /></StepUpProvider>);

    await user.type(screen.getByLabelText("Policy name"), "Release archive");
    await user.type(screen.getByLabelText("Retention days"), "90");
    await user.click(screen.getByRole("button", { name: "Review policy" }));
    await user.click(screen.getByRole("button", { name: "Create and activate policy" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Create and activate policy" })).toBeEnabled());
    expect(screen.getByRole("alertdialog")).toBeVisible();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.getByLabelText("Policy name")).toHaveValue("Release archive");
    expect(createRetentionPolicy).toHaveBeenCalledTimes(1);
  });

  it("identifies the conversation and destructive consequences when enabling retention", async () => {
    const policy = policyFixture({ status: "disabled", scope_type: "conversation", conversation_id: activeConversation.id, delete_attachments: true });
    const updateRetentionPolicy = vi.fn().mockResolvedValue({ ...policy, status: "active", version: 2 });
    const api = apiFixture({ retentionPolicies: vi.fn().mockResolvedValue([policy]), updateRetentionPolicy });
    const user = userEvent.setup();
    render(<StepUpProvider><GovernancePanel api={api} users={[]} conversations={[activeConversation]} /></StepUpProvider>);

    await user.click(await screen.findByRole("button", { name: "Enable" }));
    const dialog = screen.getByRole("alertdialog", { name: "Enable retention policy?" });
    expect(dialog).toHaveTextContent("Standard retention · Conversation: Release planning · Retain messages for 365 days.");
    expect(dialog).toHaveTextContent("without another approval");
    expect(dialog).toHaveTextContent("Attachments belonging to eligible messages are included in deletion");
    expect(within(dialog).getByRole("button", { name: "Enable policy" })).toHaveClass("danger");
    await user.type(within(dialog).getByRole("textbox", { name: "Reason for this change" }), "Approved retention schedule");
    await user.click(within(dialog).getByRole("button", { name: "Enable policy" }));
    await waitFor(() => expect(updateRetentionPolicy).toHaveBeenCalledExactlyOnceWith(policy.id, { status: "active", version: 1, reason: "Approved retention schedule" }));
  });

  it.each([
    ["user", "Alex Active", { subject_user_id: activeUser.id }],
    ["conversation", "Release planning", { conversation_id: activeConversation.id }],
    ["message", "message-to-erase", { message_id: "message-to-erase" }]
  ] as const)("names the %s target and requires an audited destructive deletion approval", async (targetType, targetLabel, targetFields) => {
    const request = deletionFixture({ target_type: targetType, ...targetFields });
    const updateDeletionRequest = vi.fn().mockResolvedValue({ ...request, status: "approved", version: 2 });
    const api = apiFixture({ deletionRequests: vi.fn().mockResolvedValue([request]), updateDeletionRequest });
    const user = userEvent.setup();
    render(<StepUpProvider><GovernancePanel api={api} users={[activeUser]} conversations={[activeConversation]} /></StepUpProvider>);

    await user.click(await screen.findByRole("button", { name: "Approve deletion" }));
    const dialog = screen.getByRole("alertdialog", { name: "Approve deletion?" });
    expect(dialog).toHaveTextContent(targetLabel);
    expect(dialog).toHaveTextContent("Requested erasure");
    expect(dialog).toHaveTextContent("Approval queues deletion for this target");
    expect(dialog).toHaveTextContent("Processing can begin immediately");
    const approve = within(dialog).getByRole("button", { name: "Approve deletion" });
    expect(approve).toHaveClass("danger");
    await user.click(approve);
    expect(updateDeletionRequest).not.toHaveBeenCalled();
    await user.type(within(dialog).getByRole("textbox", { name: "Reason for this change" }), "Verified erasure request");
    await user.click(approve);
    await waitFor(() => expect(updateDeletionRequest).toHaveBeenCalledExactlyOnceWith(request.id, { status: "approved", version: 1, transition_reason: "Verified erasure request" }));
  });

  it("does not present rejecting deletion as a destructive approval", async () => {
    const request = deletionFixture();
    const updateDeletionRequest = vi.fn();
    const api = apiFixture({ deletionRequests: vi.fn().mockResolvedValue([request]), updateDeletionRequest });
    const user = userEvent.setup();
    render(<StepUpProvider><GovernancePanel api={api} users={[activeUser]} conversations={[]} /></StepUpProvider>);

    await user.click(await screen.findByRole("button", { name: "Reject request" }));
    const dialog = screen.getByRole("alertdialog", { name: "Reject deletion request?" });
    expect(dialog).toHaveTextContent("Alex Active");
    expect(dialog).toHaveTextContent("This action does not approve deletion");
    expect(within(dialog).getByRole("button", { name: "Reject request" })).not.toHaveClass("danger");
    await user.click(within(dialog).getByRole("button", { name: "Cancel" }));
    expect(updateDeletionRequest).not.toHaveBeenCalled();
  });
});

describe("GovernancePanel target selection", () => {
  it("gives governance-load errors a descriptive dismiss control", async () => {
    const user = userEvent.setup();
    const api = apiFixture({
      retentionPolicies: vi.fn().mockRejectedValue(new Error("Governance unavailable"))
    });

    render(<StepUpProvider><GovernancePanel api={api} users={[]} conversations={[]} /></StepUpProvider>);

    const dismiss = await screen.findByRole("button", { name: "Dismiss governance error" });
    expect(screen.getByRole("alert")).toHaveTextContent("Governance unavailable");
    await user.click(dismiss);
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

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
