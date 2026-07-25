defmodule CommsCore.Accounts.GuestIdentityTest do
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
    assert guest.user.email == nil
    assert guest.user.guest_expires_at == expires_at
    assert guest_user.account_type == :guest
    assert guest_user.email == nil
    assert guest_user.password_hash == nil
    assert guest_user.guest_expires_at == expires_at
    assert guest_session.absolute_expires_at == expires_at
    assert DateTime.compare(guest_session.expires_at, expires_at) in [:lt, :eq]

    assert {:ok,
            %AccessContext{
              subject: %{
                account_type: :guest,
                guest_expires_at: ^expires_at
              }
            }} = Accounts.guest_access_context(guest.session_id, "guest-access")

    assert {:error, :session_expired} = Accounts.access_context(guest.session_id)

    assert {:ok, %AccessGrant{account_type: :guest, guest_expires_at: ^expires_at}} =
             Accounts.access_grant(subject_for(guest))
  end

  test "guest refresh is separate from normal refresh and remains bounded by guest expiry" do
    account = Fixtures.account_fixture()
    expires_at = future_time(3_600)
    guest = provision_guest(guest_attrs(account, expires_at))

    assert {:error, :invalid_refresh_token} = Accounts.refresh_session_view(guest.refresh_token)

    assert {:ok, refreshed} = Accounts.refresh_guest_session_view(guest.refresh_token)
    assert refreshed.user.id == guest.user.id
    assert refreshed.session_id == guest.session_id
    assert refreshed.refresh_token != guest.refresh_token

    refreshed_session = Repo.get!(Session, refreshed.session_id)
    assert refreshed_session.absolute_expires_at == expires_at
    assert DateTime.compare(refreshed_session.expires_at, expires_at) in [:lt, :eq]
  end

  test "expired guests lose access and no longer consume active-user quota" do
    account = Fixtures.account_fixture()
    guest = provision_guest(guest_attrs(account, future_time(3_600)))

    assert Accounts.active_user_count(account.tenant.id) == 2

    expired_at = past_time(1)

    from(user in User, where: user.id == ^guest.user.id)
    |> Repo.update_all(set: [guest_expires_at: expired_at])

    assert Accounts.active_user_count(account.tenant.id) == 1
    assert {:error, :session_expired} = Accounts.guest_access_context(guest.session_id)
    assert {:error, :forbidden} = Accounts.access_grant(subject_for(guest))

    assert {:error, :invalid_refresh_token} =
             Accounts.refresh_guest_session_view(guest.refresh_token)
  end

  test "guest conversion preserves the user id and replaces guest credentials atomically" do
    account = Fixtures.account_fixture()
    guest = provision_guest(guest_attrs(account, future_time(3_600)))
    {:ok, context} = Accounts.guest_access_context(guest.session_id, "convert-guest")

    assert {:ok, converted} =
             Accounts.convert_guest_account(
               %{
                 email: "converted@example.test",
                 password: "converted-password-123",
                 display_name: "Converted Person",
                 device: %{name: "Converted browser", platform: "web"}
               },
               context.subject,
               "converted@example.test"
             )

    assert converted.user.id == guest.user.id
    assert converted.user.account_type == :human
    assert converted.user.guest_expires_at == nil
    assert converted.user.email == "converted@example.test"
    assert converted.session_id != guest.session_id
    assert converted.device.id != guest.device.id

    converted_user = Repo.get!(User, guest.user.id)
    assert converted_user.account_type == :human
    assert converted_user.guest_expires_at == nil
    assert is_binary(converted_user.password_hash)

    assert %Session{revoked_at: %DateTime{}} = Repo.get!(Session, guest.session_id)
    assert %Device{revoked_at: %DateTime{}} = Repo.get!(Device, guest.device.id)
    assert {:error, :session_expired} = Accounts.guest_access_context(guest.session_id)

    assert {:ok, %AccessContext{user: %{id: user_id}}} =
             Accounts.access_context(converted.session_id)

    assert user_id == guest.user.id

    assert {:error, :invalid_refresh_token} =
             Accounts.refresh_guest_session_view(guest.refresh_token)
  end

  test "failed conversion rolls back and leaves the guest session usable" do
    account = Fixtures.account_fixture()
    guest = provision_guest(guest_attrs(account, future_time(3_600)))
    {:ok, context} = Accounts.guest_access_context(guest.session_id, "convert-conflict")

    device_count_before =
      Repo.aggregate(from(device in Device, where: device.user_id == ^guest.user.id), :count)

    session_count_before =
      Repo.aggregate(from(session in Session, where: session.user_id == ^guest.user.id), :count)

    assert {:error, :invalid_guest_account} =
             Accounts.convert_guest_account(
               %{
                 email: account.user.email,
                 password: "converted-password-123",
                 device: %{name: "Should roll back", platform: "web"}
               },
               context.subject,
               account.user.email
             )

    unchanged_user = Repo.get!(User, guest.user.id)
    unchanged_session = Repo.get!(Session, guest.session_id)

    assert unchanged_user.account_type == :guest
    assert unchanged_user.email == nil
    assert unchanged_session.revoked_at == nil
    assert {:ok, %AccessContext{}} = Accounts.guest_access_context(guest.session_id)

    assert Repo.aggregate(
             from(device in Device, where: device.user_id == ^guest.user.id),
             :count
           ) == device_count_before

    assert Repo.aggregate(
             from(session in Session, where: session.user_id == ^guest.user.id),
             :count
           ) == session_count_before
  end

  test "guest socket tickets retain only verified guest conversation scope" do
    account = Fixtures.account_fixture()
    guest = provision_guest(guest_attrs(account, future_time(3_600)))
    {:ok, context} = Accounts.guest_access_context(guest.session_id, "socket-issue")
    conversation_id = Ecto.UUID.generate()
    admission_id = Ecto.UUID.generate()

    subject =
      Map.merge(context.subject, %{
        guest_conversation_id: conversation_id,
        guest_admission_id: admission_id,
        guest_history_from_sequence: 12,
        ignored_untrusted_scope: "must-not-survive"
      })

    effective_deadline = future_time(30)

    Session
    |> Repo.get!(guest.session_id)
    |> Session.changeset(%{expires_at: effective_deadline})
    |> Repo.update!()

    assert {:error, :invalid_access_token} = Accounts.issue_socket_ticket(subject)

    assert {:error, :invalid_access_token} =
             Accounts.issue_guest_socket_ticket(subject)

    effective_subject = Map.put(subject, :guest_expires_at, effective_deadline)

    assert {:ok, %{ticket: ticket, expires_in: expires_in}} =
             Accounts.issue_guest_socket_ticket(effective_subject)

    assert expires_in <= 30

    assert {:ok, socket_subject} = Accounts.consume_socket_ticket(ticket)
    assert socket_subject.account_type == :guest
    assert socket_subject.guest_conversation_id == conversation_id
    assert socket_subject.guest_admission_id == admission_id
    assert socket_subject.guest_history_from_sequence == 12
    assert socket_subject.guest_expires_at == effective_deadline
    refute Map.has_key?(socket_subject, :ignored_untrusted_scope)

    assert {:error, :invalid_socket_ticket} = Accounts.consume_socket_ticket(ticket)
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

  test "direct guest conversion requires an exact preauthorized normalized email" do
    account = Fixtures.account_fixture()
    guest = provision_guest(guest_attrs(account, future_time(3_600)))
    {:ok, context} = Accounts.guest_access_context(guest.session_id, "convert-guest")

    attrs = %{
      email: "Authorized@Example.Test",
      password: "converted-password-123",
      device: %{name: "Converted browser", platform: "web"}
    }

    assert {:error, :guest_account_conversion_email_mismatch} =
             Accounts.convert_guest_account(attrs, context.subject, "different@example.test")

    assert {:ok, converted} =
             Accounts.convert_guest_account(attrs, context.subject, "authorized@example.test")

    assert converted.user.email == "authorized@example.test"
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
end
