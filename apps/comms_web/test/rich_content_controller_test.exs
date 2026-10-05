defmodule CommsWeb.RichContentControllerTest do
  use CommsWeb.ConnCase, async: false
  alias CommsCore.{Messaging, Whiteboards}
  alias CommsTestSupport.Fixtures

  setup do
    account = Fixtures.account_fixture()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    %{account: account, subject: Fixtures.subject(account), token: token}
  end

  test "public draft commands preserve version conflicts and saved endpoints scope the current identity",
       c do
    path = "/api/v1/conversations/#{c.account.conversation.id}/draft"
    assert auth(c.token) |> get(path) |> json_response(200) |> get_in(["data", "version"]) == 0

    created =
      auth(c.token)
      |> put(path, %{body: "private draft", expected_version: 0})
      |> json_response(200)

    assert created["data"]["version"] == 1

    conflict =
      auth(c.token)
      |> put(path, %{body: "stale overwrite", expected_version: 0})
      |> json_response(409)

    assert conflict["error"]["code"] == "stale_draft"

    assert auth(c.token) |> get(path) |> json_response(200) |> get_in(["data", "body"]) ==
             "private draft"

    {:ok, message} = send_message(c.account, c.subject, "saved-controller-source", "Useful notes")

    assert auth(c.token)
           |> put("/api/v1/saved-items/#{message.id}", %{})
           |> json_response(200)
           |> get_in(["data", "saved"]) == true

    saved = auth(c.token) |> get("/api/v1/saved-items") |> json_response(200)
    assert Enum.map(saved["data"], & &1["id"]) == [message.id]

    assert auth(c.token)
           |> delete("/api/v1/saved-items/#{message.id}")
           |> json_response(200)
           |> get_in(["data", "saved"]) == false

    assert auth(c.token) |> get("/api/v1/saved-items") |> json_response(200) |> Map.fetch!("data") ==
             []
  end

  test "unified candidate ranking facets cursor and scope preserve tenant isolation", c do
    {:ok, _exact} = send_message(c.account, c.subject, "search-exact-message", "planning")
    {:ok, _} = send_message(c.account, c.subject, "search-second-message", "planning project")

    {:ok, _, :created} =
      Whiteboards.append_operation(
        c.account.conversation.id,
        %{
          client_operation_id: "search-board-controller",
          kind: "scene.update",
          payload: %{
            elements: [
              %{
                id: "board-search-element",
                type: "text",
                version: 1,
                versionNonce: 1,
                text: "planning board",
                link: nil,
                customData: nil
              }
            ]
          }
        },
        c.subject
      )

    assert {:ok, board} =
             Whiteboards.rename(
               c.account.conversation.id,
               %{title: "Planning", expected_version: 1},
               c.subject
             )

    first =
      auth(c.token) |> get("/api/v1/search/unified?q=planning&limit=1") |> json_response(200)

    assert length(first["data"]) == 1
    assert Enum.at(first["data"], 0)["id"] == board.id
    assert Enum.at(first["data"], 0)["score"] > 200
    assert first["facets"]["message"] == 2
    assert first["facets"]["whiteboard"] == 2
    assert first["page"]["ranking_scope"] == "authorized_source_candidates"
    assert first["page"]["has_more"]
    cursor = URI.encode_www_form(first["page"]["next_cursor"])

    next =
      auth(c.token)
      |> get("/api/v1/search/unified?q=planning&limit=1&cursor=#{cursor}")
      |> json_response(200)

    refute Enum.at(next["data"], 0)["id"] == Enum.at(first["data"], 0)["id"]

    assert auth(c.token)
           |> get("/api/v1/search/unified?q=changed&cursor=#{cursor}")
           |> response(422)

    foreign = Fixtures.account_fixture()

    foreign_token =
      foreign
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    assert auth(foreign_token)
           |> get("/api/v1/search/unified?q=planning")
           |> json_response(200)
           |> Map.fetch!("data") == []

    assert auth(foreign_token)
           |> get("/api/v1/search/unified?q=planning&cursor=#{cursor}")
           |> response(422)
  end

  defp send_message(account, subject, key, body),
    do:
      Messaging.accept_message(
        %{
          tenant_id: account.tenant.id,
          conversation_id: account.conversation.id,
          sender_user_id: account.user.id,
          sender_device_id: account.device.id,
          client_message_id: key,
          body: body,
          attachment_ids: []
        },
        subject
      )

  defp auth(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")
end
