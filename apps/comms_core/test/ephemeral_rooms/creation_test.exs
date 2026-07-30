defmodule CommsCore.Conversations.EphemeralRooms.CreationTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query
  import CommsCore.EphemeralRoomFixtures

  alias CommsCore.{Accounts, Conversations, Repo}

  alias CommsCore.Accounts.Session

  alias CommsCore.Conversations.{
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

  test "guest creation persists digest-only authority and previews the room" do
    account = Fixtures.account_fixture()
    idempotency_key = secret()

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, idempotency_key),
               :guest
             )

    assert byte_size(created.join_token) == 43
    assert created.room.status == :active
    assert created.room.owner_kind == :guest
    assert created.authentication.user.account_type == :guest
    assert created.membership.role == :owner
    refute created.replayed

    room = Repo.get!(EphemeralRoom, created.room.id)
    link = Repo.get!(GuestLink, room.guest_link_id)
    admission = Repo.get!(GuestAdmission, created.admission.id)

    assert link.purpose == :ephemeral_room
    assert link.token_digest == created.join_token |> decode_secret!() |> sha256()
    assert byte_size(room.replay_ciphertext) > 0
    refute room.replay_ciphertext == created.join_token
    refute :erlang.term_to_binary(room) =~ created.join_token
    assert admission.session_id == created.authentication.session_id

    assert {:ok, preview} =
             Conversations.preview_ephemeral_room(created.join_token)

    assert preview.room_id == room.id
    assert preview.room_title == "Instant room"
    assert preview.status == :active

    assert {:error, :ephemeral_room_unavailable} =
             Conversations.preview_ephemeral_room(secret())
  end

  test "exact create replay returns the identical token and rebinds a usable guest session" do
    account = Fixtures.account_fixture()
    idempotency_key = secret()
    attrs = guest_create_attrs(account.tenant.id, idempotency_key)

    assert {:ok, first} = Conversations.create_ephemeral_room(attrs, :guest)
    old_session_id = first.authentication.session_id

    assert {:ok, replay} = Conversations.create_ephemeral_room(attrs, :guest)
    assert replay.replayed
    assert replay.room.id == first.room.id
    assert replay.join_token == first.join_token
    assert replay.authentication.user.id == first.authentication.user.id
    refute replay.authentication.session_id == old_session_id
    assert replay.admission.id == first.admission.id
    assert replay.membership.id == first.membership.id

    room = Repo.get!(EphemeralRoom, first.room.id)
    admission = Repo.get!(GuestAdmission, first.admission.id)

    assert room.creator_session_id == replay.authentication.session_id
    assert admission.session_id == replay.authentication.session_id
    assert %Session{revoked_at: %DateTime{}} = Repo.get!(Session, old_session_id)

    assert {:ok, _context} =
             Accounts.guest_access_context(replay.authentication.session_id, "replay-test")

    assert {:error, :idempotency_conflict} =
             Conversations.create_ephemeral_room(
               Map.put(attrs, :title, "Different request"),
               :guest
             )
  end

  test "human creation requires workspace scope and same-tenant human join is membership-idempotent" do
    owner = Fixtures.account_fixture()
    configure_public_tenant!(owner.tenant.id)
    subject = Fixtures.subject(owner)

    assert {:ok, created} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Human room"},
               subject
             )

    assert created.room.owner_kind == :registered
    assert created.authentication == nil
    assert created.membership.role == :owner

    other = Fixtures.user_fixture(owner)

    {:ok, other_session} =
      Accounts.authenticate_view(
        owner.tenant.slug,
        other.user.email,
        password_for(other.user.email),
        %{name: "Other browser", platform: "test"}
      )

    other_subject = authenticated_subject(other_session)
    join_attrs = %{idempotency_key: secret()}

    assert {:ok, joined} =
             Conversations.join_ephemeral_room(
               created.join_token,
               join_attrs,
               other_subject
             )

    assert {:ok, replayed} =
             Conversations.join_ephemeral_room(
               created.join_token,
               join_attrs,
               other_subject
             )

    refute joined.replayed
    assert joined.membership_changed
    assert replayed.replayed
    refute replayed.membership_changed
    assert replayed.membership.id == joined.membership.id

    assert {:ok, active_member_join} =
             Conversations.join_ephemeral_room(
               created.join_token,
               %{idempotency_key: secret()},
               other_subject
             )

    refute active_member_join.replayed
    refute active_member_join.membership_changed
    assert active_member_join.membership.id == joined.membership.id
  end

  test "same-tenant conversation-only humans reuse their identity for instant-room create and join" do
    account = Fixtures.account_fixture()

    assert {:ok, original_guest} =
             Conversations.create_ephemeral_room(
               guest_create_attrs(account.tenant.id, secret()),
               :guest
             )

    assert {:ok, converted} =
             Conversations.convert_guest_account(
               %{
                 email: "scoped-identity-#{System.unique_integer([:positive])}@example.test",
                 password: "correct-conversation-scoped-password-123",
                 display_name: "Scoped identity",
                 device: %{name: "Scoped browser", platform: "test"}
               },
               guest_subject(original_guest)
             )

    scoped_subject = authenticated_subject(converted.authentication)
    scoped_user_id = converted.authentication.user.id

    assert {:ok, scoped_room} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Scoped owner room"},
               scoped_subject
             )

    assert scoped_room.room.owner_kind == :registered
    assert scoped_room.room.owner_user_id == scoped_user_id
    assert scoped_room.membership.user_id == scoped_user_id
    assert scoped_room.authentication == nil
    assert scoped_room.admission == nil

    workspace_subject = Fixtures.subject(account)

    assert {:ok, target_room} =
             Conversations.create_ephemeral_room(
               %{idempotency_key: secret(), title: "Scoped join target"},
               workspace_subject
             )

    join_attrs = %{idempotency_key: secret()}

    assert {:ok, joined} =
             Conversations.join_ephemeral_room(
               target_room.join_token,
               join_attrs,
               scoped_subject
             )

    assert joined.membership.user_id == scoped_user_id
    assert joined.authentication == nil
    assert joined.admission == nil

    assert {:ok, replayed} =
             Conversations.join_ephemeral_room(
               target_room.join_token,
               join_attrs,
               scoped_subject
             )

    assert replayed.replayed
    assert replayed.membership.id == joined.membership.id

    departed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(membership in Membership, where: membership.id == ^joined.membership.id),
      set: [left_at: departed_at]
    )

    assert {:ok, rejoined} =
             Conversations.join_ephemeral_room(
               target_room.join_token,
               %{idempotency_key: secret()},
               scoped_subject
             )

    assert rejoined.membership.id == joined.membership.id
    assert rejoined.membership_changed
    assert Repo.get!(Membership, joined.membership.id).left_at == nil
    assert {:error, :forbidden} = Conversations.authorize_create(scoped_subject)

    assert {:error, :forbidden} =
             Conversations.create(%{kind: :group, title: "Workspace-only"}, scoped_subject)
  end

  test "anonymous creation requires a chosen display name" do
    account = Fixtures.account_fixture()
    configure_public_tenant!(account.tenant.id)

    assert {:error, :invalid_guest_display_name} =
             Conversations.create_ephemeral_room(
               %{
                 idempotency_key: secret(),
                 device: %{name: "Guest browser", platform: "test"}
               },
               :guest
             )

    assert {:error, :invalid_guest_display_name} =
             Conversations.create_ephemeral_room(
               %{
                 idempotency_key: secret(),
                 display_name: "   ",
                 device: %{name: "Guest browser", platform: "test"}
               },
               :guest
             )
  end
end
