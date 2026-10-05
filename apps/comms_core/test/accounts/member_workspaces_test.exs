defmodule CommsCore.Accounts.MemberWorkspacesTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.{MemberWorkspace, Session, User}
  alias CommsTestSupport.Fixtures

  @moduletag :integration

  test "new synchronized setup is read-only and two devices observe the same version" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, initial} = Accounts.member_workspace_view(subject)
    assert initial.version == 0
    assert initial.contacts == []
    assert initial.onboarding.active_devices == 1
    assert is_nil(initial.onboarding.dismissed_at)
    refute Repo.exists?(MemberWorkspace)

    assert {:ok, dismissed} =
             Accounts.update_member_onboarding(%{version: 0, action: "dismiss"}, subject)

    assert dismissed.version == 1
    assert %DateTime{} = dismissed.onboarding.dismissed_at

    suffix = account.tenant.slug |> String.split("-") |> List.last()

    assert {:ok, second} =
             Accounts.authenticate_view(
               account.tenant.slug,
               account.user.email,
               "correct-horse-battery-#{suffix}",
               %{name: "Other browser", platform: "test"}
             )

    other = %{subject | session_id: second.session_id, device_id: second.device.id}
    assert {:ok, from_other} = Accounts.member_workspace_view(other)
    assert from_other.version == dismissed.version
    assert from_other.onboarding.dismissed_at == dismissed.onboarding.dismissed_at
    assert from_other.onboarding.active_devices == 2

    assert {:ok, resumed} =
             Accounts.update_member_onboarding(
               %{version: from_other.version, action: "resume"},
               other
             )

    assert is_nil(resumed.onboarding.dismissed_at)
    assert {:ok, from_first} = Accounts.member_workspace_view(subject)
    assert from_first.version == resumed.version
  end

  test "aggregate CAS protects contacts and onboarding from another device" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account).user
    subject = Fixtures.subject(account)
    group = %{id: Ecto.UUID.generate(), name: "My colleagues", member_ids: [member.id]}

    assert {:ok, saved} =
             Accounts.replace_member_workspace(
               %{version: 0, contact_ids: [member.id], groups: [group]},
               subject
             )

    assert {:error, :stale_version} =
             Accounts.update_member_onboarding(%{version: 0, action: "dismiss"}, subject)

    assert {:error, :stale_version} =
             Accounts.replace_member_workspace(
               %{version: 0, contact_ids: [], groups: []},
               subject
             )

    assert {:ok, current} = Accounts.member_workspace_view(subject)
    assert current.version == saved.version
    assert Enum.map(current.contacts, & &1.id) == [member.id]
    assert current.groups == [group]
    assert is_nil(current.onboarding.dismissed_at)
  end

  test "private groups expose current minimal people and confer no authority" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account, %{display_name: "Duplicate name"}).user
    subject = Fixtures.subject(account)
    group = %{id: Ecto.UUID.generate(), name: "Private team", member_ids: [member.id]}

    assert {:ok, saved} =
             Accounts.replace_member_workspace(
               %{version: 0, contact_ids: [member.id], groups: [group]},
               subject
             )

    assert Map.keys(Map.from_struct(hd(saved.contacts))) |> Enum.sort() == [:display_name, :id]
    assert saved.groups == [group]
    assert Repo.get!(User, member.id).role == :member

    assert {:ok, empty_for_another} =
             Accounts.member_workspace_view(Fixtures.subject(Fixtures.account_fixture()))

    assert empty_for_another.contacts == []
    assert empty_for_another.groups == []
  end

  for excluded <- [:foreign, :suspended, :service, :self] do
    @excluded excluded
    test "#{excluded} identities cannot be stored as contacts" do
      account = Fixtures.account_fixture()

      id =
        case @excluded do
          :foreign -> Fixtures.account_fixture().user.id
          :self -> account.user.id
          :suspended -> Fixtures.user_fixture(account, %{status: :suspended}).user.id
          :service -> Fixtures.user_fixture(account, %{account_type: :service}).user.id
        end

      assert {:error, :contact_unavailable} =
               Accounts.replace_member_workspace(
                 %{version: 0, contact_ids: [id], groups: []},
                 Fixtures.subject(account)
               )

      refute Repo.exists?(MemberWorkspace)
    end
  end

  test "current authority denies a revoked session and a limited human" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    Repo.update_all(from(session in Session, where: session.id == ^account.session.id),
      set: [revoked_at: DateTime.utc_now()]
    )

    assert {:error, :forbidden} = Accounts.member_workspace_view(subject)

    assert {:error, :forbidden} =
             Accounts.replace_member_workspace(
               %{version: 0, contact_ids: [], groups: []},
               subject
             )

    limited = Fixtures.account_fixture()

    Repo.update_all(from(user in User, where: user.id == ^limited.user.id),
      set: [access_scope: :conversation_only]
    )

    assert {:error, :forbidden} = Accounts.member_workspace_view(Fixtures.subject(limited))
  end

  test "inactive references disappear from contacts and groups without cached names" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account).user
    subject = Fixtures.subject(account)

    assert {:ok, saved} =
             Accounts.replace_member_workspace(
               %{
                 version: 0,
                 contact_ids: [member.id],
                 groups: [%{id: Ecto.UUID.generate(), name: "My team", member_ids: [member.id]}]
               },
               subject
             )

    Repo.update_all(from(user in User, where: user.id == ^member.id), set: [status: :suspended])
    assert {:ok, hidden} = Accounts.member_workspace_view(subject)
    assert hidden.version == saved.version
    assert hidden.contacts == []
    assert hd(hidden.groups).member_ids == []
  end

  test "profile success records review while failed profile updates do not" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    assert {:ok, _} = Accounts.update_profile_view(%{display_name: "Reviewed profile"}, subject)
    assert {:ok, reviewed} = Accounts.member_workspace_view(subject)
    assert %DateTime{} = reviewed.onboarding.profile_reviewed_at
    assert {:error, _} = Accounts.update_profile_view(%{display_name: ""}, subject)
    assert {:ok, unchanged} = Accounts.member_workspace_view(subject)
    assert unchanged.version == reviewed.version
    assert unchanged.onboarding.profile_reviewed_at == reviewed.onboarding.profile_reviewed_at

    assert {:ok, reset} =
             Accounts.update_member_onboarding(
               %{version: unchanged.version, action: "reset"},
               subject
             )

    assert is_nil(reset.onboarding.profile_reviewed_at)
  end

  test "versions, group membership and unknown authority fields fail atomically" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:error, :version_required} =
             Accounts.replace_member_workspace(
               %{contact_ids: [], groups: []},
               subject
             )

    assert {:error, :invalid_member_workspace} =
             Accounts.replace_member_workspace(
               %{version: 0, contact_ids: [], groups: [], role: "owner"},
               subject
             )

    assert {:error, :invalid_member_workspace} =
             Accounts.replace_member_workspace(
               %{
                 version: 0,
                 contact_ids: [],
                 groups: [
                   %{
                     id: Ecto.UUID.generate(),
                     name: "Missing contact",
                     member_ids: [Ecto.UUID.generate()]
                   }
                 ]
               },
               subject
             )

    assert {:error, :invalid_onboarding_action} =
             Accounts.update_member_onboarding(%{version: 0, action: "activate_camera"}, subject)

    refute Repo.exists?(MemberWorkspace)
  end
end
