defmodule CommsWeb.WhiteboardControllerTest do
  use CommsWeb.ConnCase, async: false

  @moduletag :whiteboard
  @moduletag :integration

  alias CommsTestSupport.Fixtures

  setup do
    account = Fixtures.account_fixture()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    {:ok, account: account, authorization: {"authorization", "Bearer #{token}"}}
  end

  test "creates and replays idempotent Excalidraw scene operations", context do
    path = "/api/v1/conversations/#{context.account.conversation.id}/whiteboard/operations"

    payload = %{
      kind: "scene.update",
      base_sequence: 0,
      payload: %{
        elements: [
          %{
            id: "sdk-element-one",
            type: "rectangle",
            version: 1,
            versionNonce: 42,
            link: nil,
            customData: nil,
            x: 1,
            y: 2,
            width: 30,
            height: 40,
            isDeleted: false
          }
        ]
      }
    }

    created =
      build_conn()
      |> put_req_header(elem(context.authorization, 0), elem(context.authorization, 1))
      |> put_req_header("idempotency-key", "whiteboard-operation-one")
      |> post(path, payload)
      |> json_response(201)

    assert created["data"]["kind"] == "scene.update"
    assert created["data"]["sequence"] == 1

    replayed =
      build_conn()
      |> put_req_header(elem(context.authorization, 0), elem(context.authorization, 1))
      |> put_req_header("idempotency-key", "whiteboard-operation-one")
      |> post(path, payload)
      |> json_response(200)

    assert replayed["data"]["id"] == created["data"]["id"]

    conflict_payload = put_in(payload, [:payload, :elements, Access.at(0), :x], 99)

    conflict =
      build_conn()
      |> put_req_header(elem(context.authorization, 0), elem(context.authorization, 1))
      |> put_req_header("idempotency-key", "whiteboard-operation-one")
      |> post(path, conflict_payload)
      |> json_response(409)

    assert conflict["error"]["code"] == "idempotency_conflict"

    history =
      build_conn()
      |> put_req_header(elem(context.authorization, 0), elem(context.authorization, 1))
      |> get(path)
      |> json_response(200)

    assert Enum.map(history["data"], & &1["id"]) == [created["data"]["id"]]
    refute history["page"]["has_more"]

    build_conn()
    |> put_req_header(elem(context.authorization, 0), elem(context.authorization, 1))
    |> put_req_header("idempotency-key", "whiteboard-operation-clear")
    |> post(path, %{kind: "board.clear", payload: %{}})
    |> json_response(201)

    stale =
      build_conn()
      |> put_req_header(elem(context.authorization, 0), elem(context.authorization, 1))
      |> put_req_header("idempotency-key", "whiteboard-operation-stale")
      |> post(path, %{payload | base_sequence: 1})
      |> json_response(409)

    assert stale["error"]["code"] == "stale_whiteboard_generation"
  end

  test "rejects access outside the conversation", context do
    outsider = Fixtures.account_fixture()

    token =
      outsider
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> get("/api/v1/conversations/#{context.account.conversation.id}/whiteboard/operations")
    |> json_response(403)
  end

  test "advertises the whiteboard capability", %{conn: conn} do
    assert conn
           |> get("/api/v1/status")
           |> json_response(200)
           |> get_in(["capabilities", "whiteboards"]) == true
  end
end
