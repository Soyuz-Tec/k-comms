defmodule CommsWeb.NativeSocketTicketTest do
  use CommsWeb.ConnCase, async: false
  require Phoenix.ChannelTest
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.Session
  alias CommsTestSupport.Fixtures
  alias CommsWeb.Auth.Token

  setup do
    account = Fixtures.account_fixture()
    {:ok, issued} = Accounts.issue_socket_ticket(Fixtures.subject(account))
    %{account: account, ticket: issued.ticket}
  end

  test "native headers authenticate the real socket with the same one-use ticket", ctx do
    info = %{x_headers: [{"X-K-Comms-Socket-Ticket", ctx.ticket}]}

    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(CommsWeb.UserSocket, %{}, connect_info: info)

    assert socket.assigns.user_id == ctx.account.user.id
    assert socket.assigns.session_id == ctx.account.session.id
    assert :error = Phoenix.ChannelTest.connect(CommsWeb.UserSocket, %{}, connect_info: info)
  end

  test "query and header ambiguity refuses before consuming either valid ticket", ctx do
    assert {:ok, second} = Accounts.issue_socket_ticket(Fixtures.subject(ctx.account))

    assert {:error, :invalid_socket_ticket} =
             Token.authenticate(%{"socket_ticket" => ctx.ticket}, headers(second.ticket))

    assert {:ok, _} = Token.authenticate(%{}, headers(ctx.ticket))
    assert {:ok, _} = Token.authenticate(%{}, headers(second.ticket))
  end

  test "duplicate header and internal query spellings refuse without consuming the ticket", ctx do
    assert {:error, :invalid_socket_ticket} =
             Token.authenticate(%{}, %{
               x_headers: [
                 {"x-k-comms-socket-ticket", ctx.ticket},
                 {"X-K-COMMS-SOCKET-TICKET", ctx.ticket}
               ]
             })

    assert {:error, :invalid_socket_ticket} =
             Token.authenticate(%{"socket_ticket" => ctx.ticket, socket_ticket: ctx.ticket}, %{})

    assert {:ok, _} = Token.authenticate(%{"socket_ticket" => ctx.ticket}, %{})
  end

  test "missing, empty, malformed transport and bearer tokens never authenticate", ctx do
    access = ctx.account |> Fixtures.authentication_result() |> CommsWeb.Token.issue()

    for {params, info} <- [
          {%{}, %{}},
          {%{}, headers("")},
          {%{}, headers(42)},
          {%{}, %{x_headers: :invalid}},
          {%{"access_token" => access.access_token}, %{}},
          {%{}, headers(access.access_token)}
        ] do
      assert {:error, :invalid_socket_ticket} = Token.authenticate(params, info)
    end

    assert {:ok, _} = Token.authenticate(%{}, headers(ctx.ticket))
  end

  for boundary <- [:revoked, :expired] do
    @boundary boundary
    test "native transport cannot revive a #{@boundary} initiating session", ctx do
      case @boundary do
        :revoked ->
          assert :ok = Accounts.revoke_session(ctx.account.session.id, ctx.account.user.id)

        :expired ->
          Repo.get!(Session, ctx.account.session.id)
          |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
          |> Repo.update!()
      end

      assert {:error, :invalid_socket_ticket} = Token.authenticate(%{}, headers(ctx.ticket))
    end
  end

  defp headers(ticket), do: %{x_headers: [{"x-k-comms-socket-ticket", ticket}]}
end
