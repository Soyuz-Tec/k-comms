defmodule CommsWeb.InboxTriageControllerTest do
  use CommsWeb.ConnCase, async: false
  alias CommsCore.{Messaging, Repo}
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Messaging.PersonalContent.Draft
  alias CommsTestSupport.Fixtures
  import Ecto.Query

  setup do
    account = Fixtures.account_fixture()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    %{account: account, subject: Fixtures.subject(account), token: token}
  end

  test "bounded previews include retained sender and only this user's unexpired main draft", c do
    {:ok, message} = send_message(c, "latest", String.duplicate("界", 250))

    {:ok, _} =
      Messaging.put_draft(
        c.account.conversation.id,
        %{body: "Unsent plan", expected_version: 0},
        c.subject
      )

    %{user: other} = Fixtures.user_fixture(c.account)

    Repo.insert!(%Draft{
      tenant_id: c.account.tenant.id,
      user_id: other.id,
      conversation_id: c.account.conversation.id,
      thread_key: "main",
      body: "OTHER PRIVATE DRAFT",
      version: 1,
      expires_at: DateTime.add(DateTime.utc_now(), 60)
    })

    row = inbox(c) |> hd()
    assert row["inbox"]["message"]["id"] == message.id
    assert String.length(row["inbox"]["message"]["excerpt"]) == 200
    assert row["inbox"]["message"]["sender_display_name"] == c.account.user.display_name
    assert row["inbox"]["draft"]["excerpt"] == "Unsent plan"
    refute Jason.encode!(row) =~ "OTHER PRIVATE"
    assert row["favorite"] == false

    Repo.update_all(from(d in Draft, where: d.user_id == ^c.account.user.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert hd(inbox(c))["inbox"]["draft"] == nil
  end

  test "deleted and moderated latest bodies and attachment metadata never become previews", c do
    {:ok, message} = send_message(c, "remove", "PRIVATE OLD TEXT")

    Repo.update_all(from(m in CommsCore.Messaging.Message, where: m.id == ^message.id),
      set: [status: :deleted]
    )

    preview = hd(inbox(c))["inbox"]["message"]
    assert preview["status"] == "deleted"
    assert preview["excerpt"] == ""
    refute Jason.encode!(preview) =~ "PRIVATE OLD TEXT"

    Repo.update_all(from(m in CommsCore.Messaging.Message, where: m.id == ^message.id),
      set: [status: :moderated]
    )

    assert hd(inbox(c))["inbox"]["message"]["excerpt"] == ""
    refute Map.has_key?(preview, "attachments")
  end

  test "membership revocation, private content mode and foreign tenant IDs cannot disclose summaries",
       c do
    {:ok, _} = send_message(c, "scope", "PRIVATE PREVIEW")
    foreign = Fixtures.account_fixture()

    assert {:ok, %{}} =
             Messaging.inbox_summaries([c.account.conversation.id], Fixtures.subject(foreign))

    Repo.update_all(from(x in Conversation, where: x.id == ^c.account.conversation.id),
      set: [content_mode: :matrix_e2ee]
    )

    assert hd(inbox(c))["inbox"] == nil

    Repo.update_all(from(x in Conversation, where: x.id == ^c.account.conversation.id),
      set: [content_mode: :server_readable]
    )

    Repo.update_all(
      from(m in Membership,
        where: m.conversation_id == ^c.account.conversation.id and m.user_id == ^c.account.user.id
      ),
      set: [left_at: DateTime.utc_now()]
    )

    assert inbox(c) == []
    assert {:ok, %{}} = Messaging.inbox_summaries([c.account.conversation.id], c.subject)
  end

  test "favorites persist per membership, reject invalid values and cannot write across tenants",
       c do
    path = "/api/v1/conversations/#{c.account.conversation.id}/favorite"

    assert auth(c.token)
           |> put(path, %{favorite: true})
           |> json_response(200)
           |> get_in(["data", "favorite"])

    assert hd(inbox(c))["favorite"]

    assert auth(c.token)
           |> put(path, %{favorite: true})
           |> json_response(200)
           |> get_in(["data", "favorite"])

    assert auth(c.token) |> put(path, %{favorite: "true"}) |> response(422)
    foreign = Fixtures.account_fixture()

    token =
      foreign
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    assert auth(token) |> put(path, %{favorite: false}) |> response(404)
    assert hd(inbox(c))["favorite"]

    assert auth(c.token)
           |> put(path, %{favorite: false})
           |> json_response(200)
           |> get_in(["data", "favorite"]) == false

    refute hd(inbox(c))["favorite"]
  end

  test "revoked user cannot read previews or change favorites", c do
    Repo.update_all(from(u in CommsCore.Accounts.User, where: u.id == ^c.account.user.id),
      set: [status: :suspended]
    )

    assert {:error, _} = Messaging.inbox_summaries([c.account.conversation.id], c.subject)

    assert auth(c.token)
           |> put("/api/v1/conversations/#{c.account.conversation.id}/favorite", %{favorite: true})
           |> response(401)
  end

  defp inbox(c),
    do:
      auth(c.token)
      |> get("/api/v1/conversations?include=inbox")
      |> json_response(200)
      |> Map.fetch!("data")

  defp auth(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp send_message(c, key, body),
    do:
      Messaging.accept_message(
        %{
          tenant_id: c.account.tenant.id,
          conversation_id: c.account.conversation.id,
          sender_user_id: c.account.user.id,
          sender_device_id: c.account.device.id,
          client_message_id: "inbox-test-" <> key,
          body: body,
          attachment_ids: []
        },
        c.subject
      )
end
