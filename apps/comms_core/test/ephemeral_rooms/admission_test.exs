defmodule CommsCore.Conversations.EphemeralRooms.AdmissionTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query
  import CommsCore.EphemeralRoomFixtures

  alias CommsCore.{Conversations, Repo}

  alias CommsCore.Conversations.{
    EphemeralJoinReceipt,
    EphemeralRoom,
    GuestAdmission,
    GuestLink
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

  test "guest join is idempotent and preserves one identity, membership, and admission" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    attrs = guest_join_attrs(secret())

    assert {:ok, first} =
             Conversations.join_ephemeral_room(created.join_token, attrs, :guest)

    assert {:ok, replay} =
             Conversations.join_ephemeral_room(created.join_token, attrs, :guest)

    assert first.membership_changed
    assert replay.replayed
    refute replay.membership_changed
    assert replay.authentication.user.id == first.authentication.user.id
    assert replay.membership.id == first.membership.id
    assert replay.admission.id == first.admission.id
    refute replay.authentication.session_id == first.authentication.session_id

    assert Repo.aggregate(
             from(admission in GuestAdmission,
               where:
                 admission.guest_link_id == ^created.admission.guest_link_id and
                   not is_nil(admission.join_idempotency_digest)
             ),
             :count
           ) == 1
  end

  test "participant limit rejects excess admissions without consuming the share token" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^created.room.id),
      set: [participant_limit: 2]
    )

    assert {:ok, _first_guest} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )

    assert {:error, :conversation_member_quota_exceeded} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )

    assert Repo.get!(GuestLink, created.admission.guest_link_id).use_count == 0
  end

  test "malformed, tampered, and expired tokens are indistinguishable" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    for token <- ["not-a-token", secret()] do
      assert {:error, :ephemeral_room_unavailable} =
               Conversations.preview_ephemeral_room(token)

      assert {:error, :ephemeral_room_unavailable} =
               Conversations.join_ephemeral_room(
                 token,
                 guest_join_attrs(secret()),
                 :guest
               )
    end

    old = DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:microsecond)
    expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(link in GuestLink, where: link.id == ^created.admission.guest_link_id),
      set: [inserted_at: old, expires_at: expired]
    )

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.preview_ephemeral_room(created.join_token)

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.join_ephemeral_room(
               created.join_token,
               guest_join_attrs(secret()),
               :guest
             )
  end

  test "guest and human join receipts reject conflicts and expire after ten minutes" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    guest_key = secret()
    guest_attrs = guest_join_attrs(guest_key)

    assert {:ok, guest_join} =
             Conversations.join_ephemeral_room(created.join_token, guest_attrs, :guest)

    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(admission in GuestAdmission, where: admission.id == ^guest_join.admission.id),
      set: [admitted_at: DateTime.add(past, -600, :second), idempotency_expires_at: past]
    )

    assert {:error, :idempotency_replay_expired} =
             Conversations.join_ephemeral_room(created.join_token, guest_attrs, :guest)

    first_human = authenticated_human_fixture(account)
    second_human = authenticated_human_fixture(account)
    human_key = secret()
    human_attrs = %{idempotency_key: human_key}

    assert {:ok, first_join} =
             Conversations.join_ephemeral_room(
               created.join_token,
               human_attrs,
               first_human
             )

    assert {:error, :idempotency_conflict} =
             Conversations.join_ephemeral_room(
               created.join_token,
               human_attrs,
               second_human
             )

    receipt =
      Repo.get_by!(EphemeralJoinReceipt,
        ephemeral_room_id: created.room.id,
        membership_id: first_join.membership.id
      )

    Repo.update_all(
      from(value in EphemeralJoinReceipt, where: value.id == ^receipt.id),
      set: [inserted_at: DateTime.add(past, -600, :second), expires_at: past]
    )

    assert {:error, :idempotency_replay_expired} =
             Conversations.join_ephemeral_room(
               created.join_token,
               human_attrs,
               first_human
             )
  end

  test "guest display names accept 120 characters and reject 121" do
    account = Fixtures.account_fixture()
    configure_public_tenant!(account.tenant.id)

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{
                 idempotency_key: secret(),
                 display_name: String.duplicate("a", 120),
                 device: %{name: "Guest browser", platform: "test"}
               },
               :guest
             )

    assert String.length(created.authentication.user.display_name) == 120

    assert {:error, :invalid_guest_display_name} =
             Conversations.create_ephemeral_room(
               %{
                 idempotency_key: secret(),
                 display_name: String.duplicate("b", 121),
                 device: %{name: "Guest browser", platform: "test"}
               },
               :guest
             )
  end

  test "noncanonical Base64URL token and idempotency encodings fail closed" do
    account = Fixtures.account_fixture()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    noncanonical_token = noncanonical_encoding(created.join_token)

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.preview_ephemeral_room(noncanonical_token)

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.join_ephemeral_room(
               noncanonical_token,
               guest_join_attrs(secret()),
               :guest
             )

    assert {:error, :invalid_idempotency_key} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, noncanonical_encoding(secret())),
               :guest
             )
  end
end
