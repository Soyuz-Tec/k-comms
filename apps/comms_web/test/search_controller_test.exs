defmodule CommsWeb.SearchControllerTest do
  use CommsWeb.ConnCase, async: false

  test "search returns authorized filtered cursor pages without cross-tenant results" do
    first = bootstrap("first")
    second = bootstrap("second")

    first_messages = [
      send_message(first, "search-controller-first", "shared search token"),
      send_message(first, "search-controller-second", "shared search token")
    ]

    _other_tenant_message =
      send_message(second, "search-controller-other", "shared search token")

    query =
      URI.encode_query(%{
        q: "shared search",
        limit: 1,
        conversation_id: first.conversation_id,
        sender_user_id: first.user_id
      })

    page_one =
      authenticated_conn(first.token)
      |> get("/api/v1/search?#{query}")
      |> json_response(200)

    assert page_one["page"]["limit"] == 1
    assert page_one["page"]["has_more"]
    assert is_binary(page_one["page"]["next_cursor"])
    assert length(page_one["data"]) == 1

    page_two =
      authenticated_conn(first.token)
      |> get(
        "/api/v1/search?#{query}&#{URI.encode_query(%{cursor: page_one["page"]["next_cursor"]})}"
      )
      |> json_response(200)

    refute page_two["page"]["has_more"]
    assert page_two["page"]["next_cursor"] == nil

    assert MapSet.new(Enum.map(page_one["data"] ++ page_two["data"], & &1["id"])) ==
             MapSet.new(Enum.map(first_messages, & &1["id"]))

    assert authenticated_conn(first.token)
           |> get("/api/v1/search?q=shared+search&cursor=invalid")
           |> response(422)
  end

  defp bootstrap(label) do
    suffix = System.unique_integer([:positive, :monotonic])

    response =
      build_conn()
      |> post("/api/v1/bootstrap", %{
        tenant_name: "Search #{label} #{suffix}",
        tenant_slug: "search-#{label}-#{suffix}",
        display_name: "Search Owner",
        email: "search-#{label}-#{suffix}@example.test",
        password: "correct-horse-battery-#{suffix}"
      })
      |> json_response(201)

    %{
      token: response["access_token"],
      user_id: response["user"]["id"],
      conversation_id: response["conversation"]["id"]
    }
  end

  defp send_message(account, idempotency_key, body) do
    authenticated_conn(account.token)
    |> put_req_header("idempotency-key", idempotency_key)
    |> post("/api/v1/conversations/#{account.conversation_id}/messages", %{body: body})
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp authenticated_conn(token) do
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
