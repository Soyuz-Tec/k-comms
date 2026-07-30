defmodule CommsWeb.GuestCommunicationTestSupport do
  @moduledoc false

  import Phoenix.ConnTest
  import Plug.Conn

  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Conversations.{GuestAdmission, GuestLink}
  alias CommsCore.Repo
  @endpoint CommsWeb.Endpoint

  def setup_account(_context) do
    fixtures = Module.concat([CommsTestSupport, Fixtures])
    account = apply(fixtures, :account_fixture, [])
    apply(fixtures, :step_up, [account])

    member_token =
      account
      |> then(&apply(fixtures, :authentication_result, [&1]))
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    {:ok, account: account, member_token: member_token}
  end

  def communication_fixture(account, member_token, opts \\ []) do
    conversation_id = account.conversation.id

    old_message =
      if Keyword.get(opts, :old_message, false) do
        member_conn(member_token)
        |> put_req_header("idempotency-key", unique_key("guest-history-before"))
        |> post("/api/v1/conversations/#{conversation_id}/messages", %{body: "Before guest"})
        |> json_response(201)
      end

    link =
      member_conn(member_token)
      |> post(
        "/api/v1/conversations/#{conversation_id}/guest-links",
        Keyword.get(opts, :link_attrs, %{expires_in_seconds: 900, max_uses: 2})
      )
      |> json_response(201)

    session =
      build_conn()
      |> post("/api/v1/guest-sessions", %{
        token: link["token"],
        display_name: Keyword.get(opts, :display_name, "External Guest"),
        device: %{name: "Guest browser", platform: "test"}
      })
      |> json_response(201)

    %{
      conversation_id: conversation_id,
      link: link,
      old_message: old_message,
      session: session
    }
  end

  def member_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  def guest_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  def bound_guest_authority!(guest, link, authority_deadline, session_deadline) do
    guest_user =
      User
      |> Repo.get!(guest["user"]["id"])
      |> Ecto.Changeset.change(guest_expires_at: authority_deadline)
      |> Repo.update!()

    Session
    |> Repo.get_by!(user_id: guest_user.id)
    |> Ecto.Changeset.change(expires_at: session_deadline)
    |> Repo.update!()

    GuestLink
    |> Repo.get!(link["data"]["id"])
    |> Ecto.Changeset.change(expires_at: authority_deadline)
    |> Repo.update!()

    GuestAdmission
    |> Repo.get!(guest["admission"]["id"])
    |> Ecto.Changeset.change(expires_at: authority_deadline)
    |> Repo.update!()
  end

  def conversion_verification_digest(secret, link) do
    :crypto.hash(:sha256, [
      "k-comms:guest-conversion-verification:v1",
      <<0>>,
      link.tenant_id,
      <<0>>,
      link.conversation_id,
      <<0>>,
      link.id,
      <<0>>,
      link.conversion_email,
      <<0>>,
      secret
    ])
  end

  defp unique_key(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
