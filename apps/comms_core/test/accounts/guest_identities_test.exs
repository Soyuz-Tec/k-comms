defmodule CommsCore.Accounts.GuestIdentitiesTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Repo}

  alias CommsCore.Accounts.{
    AccessContext,
    AuthenticationResult,
    Device,
    Session,
    User
  }

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :guest

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
    assert converted.user.access_scope == :workspace
    assert converted.user.guest_expires_at == nil
    assert converted.user.email == "converted@example.test"
    assert converted.session_id != guest.session_id
    assert converted.device.id != guest.device.id

    converted_user = Repo.get!(User, guest.user.id)
    assert converted_user.account_type == :human
    assert converted_user.access_scope == :workspace
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

  test "instant-room conversion preserves continuity without workspace authority" do
    account = Fixtures.account_fixture()
    other = Fixtures.user_fixture(account, %{display_name: "Workspace Person"}).user
    guest = provision_guest(guest_attrs(account, future_time(3_600)))
    {:ok, context} = Accounts.guest_access_context(guest.session_id, "convert-ephemeral")

    subject = Map.put(context.subject, :guest_authority_purpose, :ephemeral_room)

    attrs = %{
      email: "instant-room-person@example.test",
      password: "converted-password-123"
    }

    assert {:error, :transaction_required} =
             Accounts.convert_ephemeral_guest_account(attrs, subject)

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn ->
               Accounts.convert_ephemeral_guest_account(
                 attrs,
                 Map.delete(subject, :guest_authority_purpose)
               )
             end)

    assert {:ok, converted} =
             Repo.transaction(fn ->
               case Accounts.convert_ephemeral_guest_account(attrs, subject) do
                 {:ok, result} -> result
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert converted.user.id == guest.user.id
    assert converted.user.display_name == guest.user.display_name
    assert converted.user.account_type == :human
    assert converted.user.access_scope == :conversation_only
    assert converted.user.email == "instant-room-person@example.test"
    assert converted.session_id != guest.session_id
    assert converted.device.id == guest.device.id

    assert %User{
             account_type: :human,
             access_scope: :conversation_only,
             guest_expires_at: nil
           } = Repo.get!(User, guest.user.id)

    assert %Session{revoked_at: %DateTime{}} = Repo.get!(Session, guest.session_id)
    assert %Device{revoked_at: nil} = Repo.get!(Device, guest.device.id)
    assert {:error, :session_expired} = Accounts.guest_access_context(guest.session_id)

    assert {:ok,
            %AccessContext{
              subject: %{access_scope: :conversation_only},
              user: %{access_scope: :conversation_only}
            }} = Accounts.access_context(converted.session_id)

    converted_subject =
      Session
      |> Repo.get!(converted.session_id)
      |> Accounts.subject_for_session("conversation-only-test")

    assert {:error, :forbidden} = Accounts.list_directory_views(%{}, converted_subject)
    assert Accounts.list_tenant_user_views(converted_subject) == []
    assert {:error, :forbidden} = Accounts.list_admin_user_views(converted_subject)

    assert {:error, :forbidden} =
             Accounts.create_user(
               %{
                 display_name: "Forbidden Workspace User",
                 email: "forbidden-workspace-user@example.test",
                 password: "forbidden-password-123"
               },
               converted_subject
             )

    assert Accounts.resolve_active_user_ids(account.tenant.id, [converted.user.id, other.id]) ==
             [other.id]

    assert Accounts.persisted_conversation_only_human_count() == 1
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
