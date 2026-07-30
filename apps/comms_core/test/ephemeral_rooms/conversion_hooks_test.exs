defmodule CommsCore.Conversations.EphemeralRooms.ConversionHooksTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query
  import CommsCore.EphemeralRoomFixtures

  alias CommsCore.{Conversations, Repo, RuntimePorts}

  alias CommsCore.Accounts.Session

  alias CommsCore.Conversations.{
    EphemeralPresenceLease,
    EphemeralRoom,
    GuestAdmission,
    GuestLink,
    Membership
  }

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

  test "self-service conversion preserves identity and upgrades only the guest owner" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    guest_subject = guest_subject(created)

    tab_attrs =
      Enum.map(1..5, fn _index ->
        attrs =
          guest_subject
          |> Map.put(:conversation_id, created.conversation.id)
          |> Map.put(:connection_id, secret())

        assert {:ok, _opened} = Conversations.open_ephemeral_presence(attrs)
        attrs
      end)

    assert {:ok, converted} =
             Conversations.convert_guest_account(
               %{
                 email: "instant-owner@example.test",
                 password: "correct-horse-battery-instant-owner",
                 display_name: "Instant owner",
                 device: %{name: "Converted browser", platform: "test"}
               },
               guest_subject
             )

    assert converted.authentication.user.id == created.authentication.user.id
    assert converted.authentication.user.account_type == :human
    assert converted.authentication.user.access_scope == :conversation_only
    assert converted.ephemeral_owner_upgraded

    assert %EphemeralRoom{owner_kind: :registered, creator_session_id: new_session_id} =
             Repo.get!(EphemeralRoom, created.room.id)

    assert new_session_id == converted.authentication.session_id
    converted_subject = authenticated_subject(converted.authentication)

    handed_off_leases =
      Repo.all(
        from(lease in EphemeralPresenceLease,
          where:
            lease.ephemeral_room_id == ^created.room.id and
              lease.user_id == ^converted.authentication.user.id
        )
      )

    assert length(handed_off_leases) == 5
    assert Enum.all?(handed_off_leases, &(&1.session_id == new_session_id))
    assert Enum.all?(handed_off_leases, &match?(%DateTime{}, &1.closed_at))

    Enum.each(tab_attrs, fn attrs ->
      attrs =
        converted_subject
        |> Map.put(:conversation_id, attrs.conversation_id)
        |> Map.put(:connection_id, attrs.connection_id)

      assert {:ok, _reopened} = Conversations.open_ephemeral_presence(attrs)
    end)

    assert {:error, :forbidden} = Conversations.authorize_create(converted_subject)

    assert {:error, :forbidden} =
             Conversations.create(%{kind: :group, title: "Forbidden"}, converted_subject)
  end

  test "idle guest-owner conversion extends the room, link, and active admissions to registered TTL" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    assert {:ok, joined_guest} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )

    force_past_reconnect_grace(created.room.id)
    reconciler = RuntimePorts.job_worker!(:ephemeral_room_reconciler)

    assert {:ok, {:idle, original_guest_deadline, _generation}} =
             Conversations.reconcile_ephemeral_room(
               created.room.id,
               room_generation(created.room.id),
               reconciler
             )

    assert Repo.get!(GuestLink, created.admission.guest_link_id).expires_at ==
             original_guest_deadline

    assert Repo.get!(GuestAdmission, joined_guest.admission.id).expires_at ==
             original_guest_deadline

    assert {:ok, converted} =
             Conversations.convert_guest_account(
               %{
                 email: "idle-owner-#{System.unique_integer([:positive])}@example.test",
                 password: "correct-idle-owner-password-123",
                 display_name: "Idle registered owner",
                 device: %{name: "Converted browser", platform: "test"}
               },
               guest_subject(created)
             )

    upgraded = Repo.get!(EphemeralRoom, created.room.id)

    registered_ttl =
      Application.fetch_env!(:comms_core, :instant_room_registered_idle_ttl_seconds)

    assert upgraded.owner_kind == :registered
    assert upgraded.status == :idle
    assert upgraded.expires_at == DateTime.add(upgraded.idle_since, registered_ttl, :second)
    assert DateTime.compare(upgraded.expires_at, original_guest_deadline) == :gt
    assert upgraded.authority_expires_at == upgraded.expires_at
    assert Repo.get!(GuestLink, upgraded.guest_link_id).expires_at == upgraded.expires_at
    assert Repo.get!(GuestAdmission, joined_guest.admission.id).expires_at == upgraded.expires_at

    converted_subject = authenticated_subject(converted.authentication)

    assert {:ok, rejoined} =
             Conversations.join_ephemeral_room(
               created.join_token,
               %{idempotency_key: secret()},
               converted_subject
             )

    assert rejoined.membership.user_id == converted.authentication.user.id
    assert rejoined.room.status == :active
  end

  @tag :presence
  test "explicit guest logout terminalizes room admission and presence without poisoning refresh" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    assert {:ok, joined} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )

    joined_subject = guest_subject(joined)

    presence_attrs =
      joined_subject
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    assert {:ok, opened} = Conversations.open_ephemeral_presence(presence_attrs)
    assert :ok = Conversations.logout_guest_session(joined_subject)

    assert %GuestAdmission{revoked_at: %DateTime{}} =
             Repo.get!(GuestAdmission, joined.admission.id)

    assert %Membership{left_at: %DateTime{}} =
             Repo.get!(Membership, joined.membership.id)

    assert %Session{revoked_at: %DateTime{}} =
             Repo.get!(Session, joined.authentication.session_id)

    assert %EphemeralPresenceLease{
             session_id: session_id,
             closed_at: %DateTime{}
           } = Repo.get!(EphemeralPresenceLease, opened.lease.id)

    assert session_id == joined.authentication.session_id

    refresh_due =
      DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [authority_expires_at: refresh_due]
    )

    guest_link_id = Repo.get!(EphemeralRoom, created.room.id).guest_link_id

    Repo.update_all(
      from(link in GuestLink, where: link.id == ^guest_link_id),
      set: [expires_at: refresh_due]
    )

    Repo.update_all(
      from(admission in GuestAdmission, where: admission.id == ^created.admission.id),
      set: [expires_at: refresh_due]
    )

    host_attrs =
      created
      |> guest_subject()
      |> Map.put(:conversation_id, created.conversation.id)
      |> Map.put(:connection_id, secret())

    assert {:ok, _host_presence} = Conversations.open_ephemeral_presence(host_attrs)

    refreshed = Repo.get!(EphemeralRoom, created.room.id)
    assert DateTime.compare(refreshed.authority_expires_at, refresh_due) == :gt
  end
end
