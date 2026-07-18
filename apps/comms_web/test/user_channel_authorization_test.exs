defmodule CommsWeb.UserChannelAuthorizationTest do
  use CommsWeb.ConnCase, async: false

  alias CommsCore.Accounts
  alias CommsWeb.UserChannel
  alias CommsTestSupport.Fixtures

  test "a socket may join only its own inbox and revoked sessions stop outbound events" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)
    socket = %Phoenix.Socket{assigns: subject}

    assert {:ok, %{user_id: user_id}, ^socket} =
             UserChannel.join("user:#{account.user.id}", %{}, socket)

    assert user_id == account.user.id

    assert {:error, %{reason: "forbidden"}} =
             UserChannel.join("user:#{Ecto.UUID.generate()}", %{}, socket)

    assert :ok = Accounts.revoke_session(account.session.id, account.user.id)

    assert {:stop, :unauthorized, ^socket} =
             UserChannel.handle_out("conversation.activity.v1", %{}, socket)
  end
end
