defmodule CommsWeb.SocketTicketControllerTest do
  use CommsWeb.ConnCase, async: false

  require Phoenix.ChannelTest

  test "authenticated clients mint one-time socket tickets and access tokens are rejected by sockets" do
    suffix = System.unique_integer([:positive, :monotonic])

    bootstrap =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Socket Ticket #{suffix}",
        tenant_slug: "socket-ticket-#{suffix}",
        display_name: "Socket Owner",
        email: "socket-owner-#{suffix}@example.test",
        password: "correct-horse-socket-ticket-#{suffix}"
      })
      |> json_response(201)

    access_token = bootstrap["access_token"]

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> post("/api/v1/socket-tickets", %{})
      |> json_response(201)

    ticket = response["data"]["ticket"]
    assert is_binary(ticket)
    assert response["data"]["expires_in"] <= 120

    assert {:error, :invalid_socket_ticket} =
             CommsWeb.Auth.Token.authenticate(%{"access_token" => access_token}, %{})

    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(CommsWeb.UserSocket, %{"socket_ticket" => ticket})

    assert socket.assigns.user_id == bootstrap["user"]["id"]

    assert :error =
             Phoenix.ChannelTest.connect(CommsWeb.UserSocket, %{"socket_ticket" => ticket})
  end
end
