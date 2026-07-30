defmodule CommsCore.Accounts.AccessControlTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.{AccessGrant, Device, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.{Audit, Repo}
  alias CommsTestSupport.Fixtures

  @moduletag :integration

  test "access grants validate the active tenant, human user, device, and session" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok,
            %AccessGrant{
              tenant_id: tenant_id,
              user_id: user_id,
              device_id: device_id,
              session_id: session_id,
              role: :owner,
              step_up_recent?: false
            }} = Accounts.access_grant(subject)

    assert tenant_id == account.tenant.id
    assert user_id == account.user.id
    assert device_id == account.device.id
    assert session_id == account.session.id

    account.session |> Session.changeset(%{revoked_at: timestamp}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.access_grant(subject)

    Repo.get!(Session, account.session.id)
    |> Session.changeset(%{revoked_at: nil})
    |> Repo.update!()

    account.device |> Device.changeset(%{revoked_at: timestamp}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.access_grant(subject)

    Repo.get!(Device, account.device.id)
    |> Device.changeset(%{revoked_at: nil})
    |> Repo.update!()

    account.user |> User.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.access_grant(subject)

    Repo.get!(User, account.user.id)
    |> User.changeset(%{status: :active})
    |> Repo.update!()

    account.tenant |> Tenant.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.access_grant(subject)

    Repo.get!(Tenant, account.tenant.id)
    |> Tenant.changeset(%{status: :active})
    |> Repo.update!()

    expired_at = DateTime.add(timestamp, -1, :second)

    Repo.get!(Session, account.session.id)
    |> Session.changeset(%{expires_at: expired_at})
    |> Repo.update!()

    assert {:error, :forbidden} = Accounts.access_grant(subject)
  end

  test "inactive privileged subjects retain verified denial audit evidence" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    account.session |> Session.changeset(%{revoked_at: timestamp}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.authorize_manage_user_lifecycle(subject)
    assert denial_count(account) == 1

    Repo.get!(Session, account.session.id)
    |> Session.changeset(%{revoked_at: nil})
    |> Repo.update!()

    account.device |> Device.changeset(%{revoked_at: timestamp}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.authorize_manage_user_lifecycle(subject)
    assert denial_count(account) == 2

    Repo.get!(Device, account.device.id)
    |> Device.changeset(%{revoked_at: nil})
    |> Repo.update!()

    account.user |> User.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.authorize_manage_user_lifecycle(subject)
    assert denial_count(account) == 3

    Repo.get!(User, account.user.id)
    |> User.changeset(%{status: :active})
    |> Repo.update!()

    account.tenant |> Tenant.changeset(%{status: :suspended}) |> Repo.update!()
    assert {:error, :forbidden} = Accounts.authorize_manage_user_lifecycle(subject)
    assert denial_count(account) == 4
  end

  test "identity authorization uses persisted role and recent step-up facts" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert :ok =
             Accounts.authorize_receive_user_events(subject, %{user_id: account.user.id})

    assert {:error, :forbidden} =
             Accounts.authorize_receive_user_events(subject, %{user_id: Ecto.UUID.generate()})

    assert {:error, :step_up_required} =
             Accounts.authorize_manage_user_lifecycle(subject)

    assert {:error, :step_up_required} = Accounts.authorize_manage_sessions(subject)

    stepped_up_subject = Fixtures.step_up(account, subject)

    assert {:ok, %AccessGrant{role: :owner, step_up_recent?: true}} =
             Accounts.access_grant(stepped_up_subject)

    assert :ok = Accounts.authorize_manage_user_lifecycle(stepped_up_subject)
    assert :ok = Accounts.authorize_manage_sessions(stepped_up_subject)

    stale_step_up =
      DateTime.utc_now()
      |> DateTime.add(
        -Application.get_env(:comms_core, :step_up_ttl_seconds, 300) - 1,
        :second
      )
      |> DateTime.truncate(:microsecond)

    Repo.get!(Session, account.session.id)
    |> Session.changeset(%{step_up_at: stale_step_up})
    |> Repo.update!()

    assert {:ok, %AccessGrant{step_up_recent?: false}} =
             Accounts.access_grant(stepped_up_subject)

    assert {:error, :step_up_required} =
             Accounts.authorize_manage_user_lifecycle(stepped_up_subject)
  end

  defp denial_count(account) do
    Audit.count(%{
      tenant_id: account.tenant.id,
      actor_user_id: account.user.id,
      action: "authorization.denied"
    })
  end
end
