defmodule CommsCore.Accounts.GuestIdentitySessionLifecycleTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Repo}

  alias CommsCore.Accounts.{
    AccessContext,
    AccessGrant,
    AuthenticationResult,
    Device,
    Session,
    User
  }

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :guest

  test "guest provisioning requires a caller transaction and creates a bounded guest session" do
    account = Fixtures.account_fixture()
    expires_at = future_time(3_600)

    attrs = guest_attrs(account, expires_at)

    assert {:error, :transaction_required} = Accounts.provision_guest_identity(attrs)

    guest = provision_guest(attrs)
    guest_user = Repo.get!(User, guest.user.id)
    guest_session = Repo.get!(Session, guest.session_id)

    assert %AuthenticationResult{} = guest
    assert guest.user.account_type == :guest
    assert guest.user.access_scope == :conversation_only
    assert guest.user.email == nil
    assert guest.user.guest_expires_at == expires_at
    assert guest_user.account_type == :guest
    assert guest_user.access_scope == :conversation_only
    assert guest_user.email == nil
    assert guest_user.password_hash == nil
    assert guest_user.guest_expires_at == expires_at
    assert guest_session.absolute_expires_at == expires_at
    assert DateTime.compare(guest_session.expires_at, expires_at) in [:lt, :eq]

    assert {:ok,
            %AccessContext{
              subject: %{
                account_type: :guest,
                access_scope: :conversation_only,
                guest_expires_at: ^expires_at
              }
            }} = Accounts.guest_access_context(guest.session_id, "guest-access")

    assert {:error, :session_expired} = Accounts.access_context(guest.session_id)

    assert {:ok,
            %AccessGrant{
              account_type: :guest,
              access_scope: :conversation_only,
              guest_expires_at: ^expires_at
            }} =
             Accounts.access_grant(subject_for(guest))
  end

  test "instant-room authority extension is transaction-only, monotonic, and bounded" do
    account = Fixtures.account_fixture()
    initial_deadline = future_time(3_600)
    guest = provision_guest(guest_attrs(account, initial_deadline))
    extended_deadline = future_time(7_200)

    assert {:error, :transaction_required} =
             Accounts.extend_ephemeral_guest_authority(
               guest.session_id,
               extended_deadline
             )

    assert {:ok, receipt} =
             Repo.transaction(fn ->
               case Accounts.extend_ephemeral_guest_authority(
                      guest.session_id,
                      extended_deadline
                    ) do
                 {:ok, value} -> value
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert receipt == %{
             tenant_id: account.tenant.id,
             user_id: guest.user.id,
             session_id: guest.session_id,
             expires_at: extended_deadline
           }

    extended_user = Repo.get!(User, guest.user.id)
    extended_session = Repo.get!(Session, guest.session_id)
    extended_device = Repo.get!(Device, guest.device.id)

    assert extended_user.guest_expires_at == extended_deadline
    assert extended_session.absolute_expires_at == extended_deadline
    assert extended_session.expires_at == extended_deadline
    assert %DateTime{} = extended_device.last_seen_at

    assert {:ok, {:error, :invalid_ephemeral_guest_deadline}} =
             Repo.transaction(fn ->
               Accounts.extend_ephemeral_guest_authority(
                 guest.session_id,
                 DateTime.add(extended_deadline, -60, :second)
               )
             end)

    covered_deadline = DateTime.add(extended_deadline, -60, :second)

    assert {:error, :transaction_required} =
             Accounts.ensure_ephemeral_guest_authority(guest.session_id, covered_deadline)

    assert {:ok, coverage_receipt} =
             Repo.transaction(fn ->
               case Accounts.ensure_ephemeral_guest_authority(
                      guest.session_id,
                      covered_deadline
                    ) do
                 {:ok, value} -> value
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert coverage_receipt.expires_at == covered_deadline
    assert Repo.get!(User, guest.user.id).guest_expires_at == extended_deadline
    assert Repo.get!(Session, guest.session_id).absolute_expires_at == extended_deadline
    assert Repo.get!(Session, guest.session_id).expires_at == extended_deadline

    assert {:ok, {:error, :invalid_ephemeral_guest_deadline}} =
             Repo.transaction(fn ->
               Accounts.extend_ephemeral_guest_authority(
                 guest.session_id,
                 future_time(90_000)
               )
             end)

    refute Session.changeset(extended_session, %{
             absolute_expires_at: future_time(8_000)
           }).valid?
  end

  test "authority maintenance does not fabricate session or device activity" do
    account = Fixtures.account_fixture()
    initial_deadline = future_time(3_600)
    guest = provision_guest(guest_attrs(account, initial_deadline))
    stale_activity_at = past_time(600)

    from(session in Session, where: session.id == ^guest.session_id)
    |> Repo.update_all(set: [last_used_at: stale_activity_at, updated_at: stale_activity_at])

    from(device in Device, where: device.id == ^guest.device.id)
    |> Repo.update_all(set: [last_seen_at: stale_activity_at, updated_at: stale_activity_at])

    extended_deadline = future_time(7_200)

    assert {:ok, %{expires_at: ^extended_deadline}} =
             Repo.transaction(fn ->
               case Accounts.ensure_ephemeral_guest_authority(
                      guest.session_id,
                      extended_deadline
                    ) do
                 {:ok, receipt} -> receipt
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    extended_user = Repo.get!(User, guest.user.id)
    extended_session = Repo.get!(Session, guest.session_id)
    extended_device = Repo.get!(Device, guest.device.id)

    assert extended_session.last_used_at == stale_activity_at
    assert extended_device.last_seen_at == stale_activity_at

    covered_deadline = DateTime.add(extended_deadline, -60, :second)

    assert {:ok, %{expires_at: ^covered_deadline}} =
             Repo.transaction(fn ->
               case Accounts.ensure_ephemeral_guest_authority(
                      guest.session_id,
                      covered_deadline
                    ) do
                 {:ok, receipt} -> receipt
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    covered_user = Repo.get!(User, guest.user.id)
    covered_session = Repo.get!(Session, guest.session_id)
    covered_device = Repo.get!(Device, guest.device.id)

    assert covered_user.lock_version == extended_user.lock_version
    assert covered_session.updated_at == extended_session.updated_at
    assert covered_device.updated_at == extended_device.updated_at
    assert covered_session.last_used_at == stale_activity_at
    assert covered_device.last_seen_at == stale_activity_at
  end

  test "strict authority extension rejects a receipt beyond the sliding session deadline" do
    restore_session_ttl = preserve_env(:session_ttl_seconds)
    on_exit(restore_session_ttl)
    Application.put_env(:comms_core, :session_ttl_seconds, 600)

    account = Fixtures.account_fixture()
    initial_deadline = future_time(3_600)
    guest = provision_guest(guest_attrs(account, initial_deadline))
    requested_deadline = future_time(7_200)

    assert {:ok, {:error, :invalid_ephemeral_guest_deadline}} =
             Repo.transaction(fn ->
               Accounts.extend_ephemeral_guest_authority(
                 guest.session_id,
                 requested_deadline
               )
             end)

    assert Repo.get!(User, guest.user.id).guest_expires_at == initial_deadline
    assert Repo.get!(Session, guest.session_id).absolute_expires_at == initial_deadline
  end

  test "instant-room idempotency replay reissues guest authentication without widening scope" do
    account = Fixtures.account_fixture()
    initial_deadline = future_time(3_600)
    resumed_deadline = future_time(7_200)
    guest = provision_guest(guest_attrs(account, initial_deadline))

    command = %{
      user_id: guest.user.id,
      session_id: guest.session_id,
      expires_at: resumed_deadline,
      device: %{name: "Resumed guest browser", platform: "test"},
      guest_authority_purpose: :ephemeral_room
    }

    assert {:error, :transaction_required} =
             Accounts.resume_ephemeral_guest_identity(command)

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn ->
               command
               |> Map.delete(:guest_authority_purpose)
               |> Accounts.resume_ephemeral_guest_identity()
             end)

    assert {:ok, resumed} =
             Repo.transaction(fn ->
               case Accounts.resume_ephemeral_guest_identity(command) do
                 {:ok, result} -> result
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert resumed.user.id == guest.user.id
    assert resumed.user.account_type == :guest
    assert resumed.user.access_scope == :conversation_only
    assert resumed.user.guest_expires_at == resumed_deadline
    assert resumed.device.id == guest.device.id
    assert resumed.device.name == "Resumed guest browser"
    assert resumed.session_id != guest.session_id
    assert is_binary(resumed.refresh_token)

    assert %Session{revoked_at: %DateTime{}} = Repo.get!(Session, guest.session_id)

    assert %Session{
             revoked_at: nil,
             absolute_expires_at: ^resumed_deadline
           } = Repo.get!(Session, resumed.session_id)

    assert {:error, :invalid_refresh_token} =
             Accounts.refresh_guest_session_view(guest.refresh_token)

    assert {:ok, refreshed} =
             Accounts.refresh_guest_session_view(resumed.refresh_token)

    assert refreshed.session_id == resumed.session_id
    assert refreshed.user.id == guest.user.id
  end

  test "ephemeral identity handoffs reject cross-tenant session authority" do
    first_account = Fixtures.account_fixture()
    second_account = Fixtures.account_fixture()
    deadline = future_time(3_600)
    first_guest = provision_guest(guest_attrs(first_account, deadline))
    second_guest = provision_guest(guest_attrs(second_account, deadline))

    assert {:ok, {:error, :session_expired}} =
             Repo.transaction(fn ->
               Accounts.resume_ephemeral_guest_identity(%{
                 user_id: first_guest.user.id,
                 session_id: second_guest.session_id,
                 expires_at: deadline,
                 guest_authority_purpose: :ephemeral_room
               })
             end)

    {:ok, context} =
      Accounts.guest_access_context(first_guest.session_id, "cross-tenant-conversion")

    foreign_tenant_subject =
      context.subject
      |> Map.put(:tenant_id, second_account.tenant.id)
      |> Map.put(:guest_authority_purpose, :ephemeral_room)

    assert {:ok, {:error, :session_expired}} =
             Repo.transaction(fn ->
               Accounts.convert_ephemeral_guest_account(
                 %{
                   email: "cross-tenant-identity@example.test",
                   password: "converted-password-123"
                 },
                 foreign_tenant_subject
               )
             end)

    assert %Session{revoked_at: nil} = Repo.get!(Session, first_guest.session_id)
    assert %Session{revoked_at: nil} = Repo.get!(Session, second_guest.session_id)
    assert %Device{revoked_at: nil} = Repo.get!(Device, first_guest.device.id)
    assert %Device{revoked_at: nil} = Repo.get!(Device, second_guest.device.id)
  end

  test "guest session revocation is idempotent and denies future access" do
    account = Fixtures.account_fixture()
    guest = provision_guest(guest_attrs(account, future_time(3_600)))

    assert :ok = Accounts.revoke_guest_session(guest.session_id, "guest_link_revoked")
    assert Accounts.active_user_count(account.tenant.id) == 1

    assert %User{guest_expires_at: %DateTime{} = expires_at} =
             Repo.get!(User, guest.user.id)

    assert DateTime.compare(expires_at, DateTime.utc_now()) in [:lt, :eq]
    assert :ok = Accounts.revoke_guest_session(guest.session_id, "guest_link_revoked")
    assert Accounts.active_user_count(account.tenant.id) == 1
    assert {:error, :session_expired} = Accounts.guest_access_context(guest.session_id)
    assert {:error, :invalid_reason} = Accounts.revoke_guest_session(guest.session_id, "")
  end

  test "guest session revocation rejects malformed UUIDs without raising" do
    assert {:error, :not_found} =
             Accounts.revoke_guest_session("not-a-uuid", "guest_link_revoked")
  end

  defp provision_guest(attrs) do
    assert {:ok, %AuthenticationResult{} = guest} =
             Repo.transaction(fn ->
               case Accounts.provision_guest_identity(attrs) do
                 {:ok, result} -> result
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    guest
  end

  defp guest_attrs(account, expires_at) do
    %{
      tenant_id: account.tenant.id,
      display_name: "Link Guest",
      expires_at: expires_at,
      device: %{name: "Guest browser", platform: "test"},
      request_id: "guest-test-request"
    }
  end

  defp subject_for(guest) do
    %{
      tenant_id: guest.tenant.id,
      user_id: guest.user.id,
      device_id: guest.device.id,
      session_id: guest.session_id,
      request_id: "guest-subject"
    }
  end

  defp future_time(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:microsecond)

  defp past_time(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:microsecond)

  defp preserve_env(key) do
    previous = Application.fetch_env(:comms_core, key)

    fn ->
      case previous do
        {:ok, value} -> Application.put_env(:comms_core, key, value)
        :error -> Application.delete_env(:comms_core, key)
      end
    end
  end
end
