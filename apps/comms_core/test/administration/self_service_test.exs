defmodule CommsCore.Administration.SelfServiceTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration

  alias CommsCore.{Accounts, Audit, Repo}
  alias CommsCore.Accounts.SocketTicket
  alias CommsTestSupport.Fixtures

  test "profile, password, device, and session self-service are audited" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, second_login} =
             Accounts.authenticate_view(
               account.tenant.slug,
               account.user.email,
               fixture_password(account),
               %{name: "Second device", platform: "test"}
             )

    assert {:ok, updated} =
             Accounts.update_profile(%{display_name: "Updated Owner"}, subject)

    assert updated.display_name == "Updated Owner"

    assert {:ok, same_email} =
             Accounts.update_profile(
               %{
                 display_name: "Same Email Owner",
                 email: "  #{String.upcase(account.user.email)}  "
               },
               subject
             )

    assert same_email.display_name == "Same Email Owner"
    assert same_email.email == account.user.email

    assert {:error, :email_change_requires_verification} =
             Accounts.update_profile(
               %{display_name: "Rejected Email Owner", email: "attacker@example.test"},
               subject
             )

    unchanged = Repo.get!(CommsCore.Accounts.User, account.user.id)
    assert unchanged.display_name == "Same Email Owner"
    assert unchanged.email == account.user.email

    assert {:ok, _} =
             Accounts.change_password(
               %{
                 current_password: fixture_password(account),
                 new_password: "correct-horse-new-owner-password"
               },
               subject
             )

    assert {:error, :session_expired} = Accounts.get_active_session(second_login.session_id)
    assert {:ok, device_result} = Accounts.revoke_device(account.device.id, subject)
    assert account.session.id in device_result.revoked_session_ids

    assert Audit.get_by(%{
             tenant_id: account.tenant.id,
             action: "user.password_change"
           })
  end

  test "socket tickets are short-lived, hashed, and consumed exactly once" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    stale_id = Ecto.UUID.generate()

    stale_at =
      DateTime.add(DateTime.utc_now(), -7_200, :second) |> DateTime.truncate(:microsecond)

    assert {:ok, _stale} =
             %SocketTicket{id: stale_id}
             |> SocketTicket.changeset(%{
               tenant_id: account.tenant.id,
               user_id: account.user.id,
               device_id: account.device.id,
               session_id: account.session.id,
               token_hash: :crypto.hash(:sha256, "stale-ticket-secret"),
               expires_at: stale_at,
               consumed_at: stale_at
             })
             |> Repo.insert()

    assert {:ok, issued} = Accounts.issue_socket_ticket(subject)
    refute Repo.get(SocketTicket, stale_id)
    assert is_binary(issued.ticket)
    assert issued.expires_in <= 120

    [ticket_id, _secret] = String.split(issued.ticket, ".", parts: 2)
    stored = Repo.get!(SocketTicket, ticket_id)
    refute issued.ticket =~ Base.url_encode64(stored.token_hash, padding: false)
    assert is_nil(stored.consumed_at)

    assert {:ok, consumed_subject} = Accounts.consume_socket_ticket(issued.ticket)
    assert consumed_subject.user_id == account.user.id
    assert Repo.get!(SocketTicket, ticket_id).consumed_at

    assert {:error, :invalid_socket_ticket} = Accounts.consume_socket_ticket(issued.ticket)

    assert 1 == Audit.count(%{tenant_id: account.tenant.id, action: "socket_ticket.issue"})

    assert 1 == Audit.count(%{tenant_id: account.tenant.id, action: "socket_ticket.consume"})
  end

  defp fixture_password(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()
    "correct-horse-battery-#{suffix}"
  end
end
