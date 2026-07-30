defmodule CommsCore.Moderation.CasesTest do
  use CommsCore.DataCase, async: false

  import CommsCore.TrustGovernanceTestSupport

  alias CommsCore.{Audit, Moderation}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :moderation

  test "members report idempotently and moderators resolve with version checks" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    owner_subject = Fixtures.step_up(account)

    assert {:ok, conversation} =
             CommsCore.Conversations.create(
               %{
                 title: "Safety",
                 kind: "group",
                 member_ids: [member.user.id]
               },
               owner_subject
             )

    member_subject = authenticated_subject(account, member.user, "member-browser")

    attrs = %{
      conversation_id: conversation.id,
      subject_user_id: account.user.id,
      category: "harassment",
      summary: "Repeated unwanted messages",
      details: "Reported through the in-product safety workflow",
      idempotency_key: "report-001"
    }

    assert {:ok, first} = Moderation.create_case(attrs, member_subject)
    assert first.replayed == false
    assert {:ok, replay} = Moderation.create_case(attrs, member_subject)
    assert replay.replayed == true
    assert replay.case.id == first.case.id

    assert {:error, :forbidden} = Moderation.list_cases(%{}, member_subject)
    assert {:ok, [_]} = Moderation.list_cases(%{status: "open"}, owner_subject)

    assert {:ok, result} =
             Moderation.add_action(
               first.case.id,
               %{version: 1, action_type: "resolve", note: "Reviewed and resolved"},
               owner_subject
             )

    assert result.case.status == :resolved
    assert result.case.lock_version == 2
    assert result.action.action_type == :resolve

    assert {:error, :stale_version} =
             Moderation.add_action(
               first.case.id,
               %{version: 1, action_type: "reopen"},
               owner_subject
             )
  end

  test "moderation owns its role, step-up, and denial policies" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    moderator = Fixtures.user_fixture(account, %{role: :moderator})
    compliance = Fixtures.user_fixture(account, %{role: :compliance_admin})

    owner_subject = Fixtures.subject(account)
    member_subject = authenticated_subject(account, member.user, "member-policy-browser")
    moderator_subject = authenticated_subject(account, moderator.user, "moderator-policy-browser")

    compliance_subject =
      authenticated_subject(account, compliance.user, "compliance-policy-browser")

    assert :ok = Moderation.authorize_report(member_subject)
    assert {:error, :forbidden} = Moderation.authorize_read(member_subject)
    assert {:error, :forbidden} = Moderation.authorize_manage(member_subject)

    assert :ok = Moderation.authorize_read(moderator_subject)
    assert {:error, :step_up_required} = Moderation.authorize_manage(moderator_subject)

    assert :ok = Moderation.authorize_read(compliance_subject)
    assert {:error, :step_up_required} = Moderation.authorize_manage(compliance_subject)

    assert :ok = Moderation.authorize_read(owner_subject)
    assert {:error, :step_up_required} = Moderation.authorize_manage(owner_subject)

    denied_permissions =
      Audit.list(%{
        tenant_id: account.tenant.id,
        action: "authorization.denied",
        limit: 20
      })
      |> Enum.map(& &1.metadata["permission"])
      |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new(["manage_moderation", "moderate_tenant"]),
             denied_permissions
           )

    stepped_up_owner = Fixtures.step_up(account, owner_subject)

    assert :ok = Moderation.authorize_report(stepped_up_owner)
    assert :ok = Moderation.authorize_read(stepped_up_owner)
    assert :ok = Moderation.authorize_manage(stepped_up_owner)
    assert {:ok, []} = Moderation.list_cases(%{}, stepped_up_owner)
  end
end
