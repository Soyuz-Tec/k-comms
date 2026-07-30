defmodule CommsWeb.GuestCommunication.LinkAvailabilityTest do
  use CommsWeb.ConnCase, async: false

  import CommsWeb.GuestCommunicationTestSupport

  @moduletag :integration
  @moduletag :guest

  setup :setup_account

  test "invalid, revoked, and unknown links share one public error", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1
      })
      |> json_response(201)

    member_conn(member_token)
    |> delete("/api/v1/conversations/#{conversation_id}/guest-links/#{link["data"]["id"]}")
    |> json_response(200)

    revoked = unavailable_preview(link["token"])

    unknown =
      unavailable_preview(
        "#{Ecto.UUID.generate()}.#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"
      )

    malformed = unavailable_preview("not-a-canonical-guest-link")

    assert revoked == unknown
    assert malformed == unknown
    assert unknown == unavailable_response()
  end

  test "exhausted links use the same public error as unknown links", %{
    account: account,
    member_token: member_token
  } do
    conversation_id = account.conversation.id

    link =
      member_conn(member_token)
      |> post("/api/v1/conversations/#{conversation_id}/guest-links", %{
        expires_in_seconds: 900,
        max_uses: 1
      })
      |> json_response(201)

    build_conn()
    |> post("/api/v1/guest-sessions", %{
      token: link["token"],
      display_name: "Only admitted guest",
      device: %{name: "Guest browser", platform: "test"}
    })
    |> json_response(201)

    exhausted = unavailable_preview(link["token"])

    unknown =
      unavailable_preview(
        "#{Ecto.UUID.generate()}.#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"
      )

    assert exhausted == unknown
    assert exhausted == unavailable_response()
  end

  defp unavailable_preview(token) do
    build_conn()
    |> post("/api/v1/guest-links/preview", %{token: token})
    |> json_response(404)
  end

  defp unavailable_response do
    %{
      "error" => %{
        "code" => "guest_link_unavailable",
        "detail" => "This guest communication link is unavailable"
      }
    }
  end
end
