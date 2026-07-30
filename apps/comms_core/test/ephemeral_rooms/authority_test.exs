defmodule CommsCore.Conversations.EphemeralRooms.AuthorityTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query
  import CommsCore.EphemeralRoomFixtures

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Conversations.EphemeralRoom

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation

  setup do
    enabled = Application.get_env(:comms_core, :instant_rooms_enabled)
    slug = Application.get_env(:comms_core, :instant_room_tenant_slug)

    on_exit(fn ->
      restore_env(:instant_rooms_enabled, enabled)
      restore_env(:instant_room_tenant_slug, slug)
    end)

    :ok
  end

  test "configured public tenant is authoritative for guest and registered creation" do
    public = Fixtures.account_fixture()
    foreign = Fixtures.account_fixture()
    configure_public_tenant!(public.tenant.id)

    assert {:ok, guest_room} =
             Conversations.create_ephemeral_room(
               %{
                 tenant_id: foreign.tenant.id,
                 idempotency_key: secret(),
                 display_name: "Public guest",
                 device: %{name: "Guest browser", platform: "test"}
               },
               :guest
             )

    assert guest_room.authentication.tenant.id == public.tenant.id

    assert {:error, :forbidden} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Cross tenant"},
               Fixtures.subject(foreign)
             )
  end

  @tag :presence
  @tag :concurrency
  test "an overdue idle room cannot be reactivated before delayed expiry work runs" do
    account = Fixtures.account_fixture()
    configure_public_tenant!(account.tenant.id)
    subject = Fixtures.subject(account)

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Overdue room"},
               subject
             )

    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [status: :idle, idle_since: DateTime.add(past, -60, :second), expires_at: past]
    )

    attrs =
      subject
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.open_ephemeral_presence(attrs)

    assert Repo.get!(EphemeralRoom, created.room.id).status == :idle
  end

  test "feature disable fails preview, join, and self-service conversion closed" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    guest_subject = guest_subject(created)
    Application.put_env(:comms_core, :instant_rooms_enabled, false)

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.preview_ephemeral_room(created.join_token)

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )

    assert {:error, :instant_rooms_unavailable} =
             Conversations.convert_guest_account(
               %{
                 email: "disabled@example.test",
                 password: "correct-horse-battery-disabled"
               },
               guest_subject
             )
  end
end
