defmodule CommsCore.EphemeralRoomFixtures do
  @moduledoc false

  import Ecto.Query
  import ExUnit.Assertions

  alias CommsCore.Accounts
  alias CommsCore.Conversations.EphemeralRoom
  alias CommsCore.Repo

  @token_bytes 32

  def guest_create_attrs(tenant_id, idempotency_key) do
    configure_public_tenant!(tenant_id)

    %{
      tenant_id: tenant_id,
      idempotency_key: idempotency_key,
      display_name: "Guest host",
      device: %{name: "Guest browser", platform: "test"},
      request_id: "ephemeral-room-test"
    }
  end

  def guest_join_attrs(idempotency_key) do
    %{
      idempotency_key: idempotency_key,
      display_name: "Joining guest",
      device: %{name: "Guest browser", platform: "test"},
      request_id: "ephemeral-room-join-test"
    }
  end

  def guest_subject(result) do
    assert {:ok, context} =
             Accounts.guest_access_context(
               result.authentication.session_id,
               "ephemeral-presence-test"
             )

    Map.merge(context.subject, %{
      guest_admission_id: result.admission.id,
      guest_conversation_id: result.conversation.id,
      guest_history_from_sequence: result.admission.history_from_sequence
    })
  end

  def authenticated_subject(authentication) do
    %{
      tenant_id: authentication.tenant.id,
      user_id: authentication.user.id,
      device_id: authentication.device.id,
      session_id: authentication.session_id,
      role: authentication.user.role,
      request_id: "ephemeral-human-join-test"
    }
  end

  def password_for(email) do
    suffix =
      email
      |> String.replace_prefix("member-", "")
      |> String.replace_suffix("@example.test", "")

    "correct-horse-battery-#{suffix}"
  end

  def authenticated_human_fixture(account) do
    fixtures = Module.concat([CommsTestSupport, Fixtures])
    member = apply(fixtures, :user_fixture, [account])

    {:ok, authentication} =
      Accounts.authenticate_view(
        account.tenant.slug,
        member.user.email,
        password_for(member.user.email),
        %{name: "Member browser", platform: "test"}
      )

    authenticated_subject(authentication)
  end

  def secret,
    do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  def force_past_reconnect_grace(room_id) do
    old = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(room in EphemeralRoom, where: room.id == ^room_id),
      set: [last_presence_at: old, inserted_at: old]
    )
  end

  def room_generation(room_id), do: Repo.get!(EphemeralRoom, room_id).generation

  def noncanonical_encoding(value) do
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    canonical_last = String.last(value)
    index = :binary.match(alphabet, canonical_last) |> elem(0)
    replacement = String.at(alphabet, index + 1)
    String.slice(value, 0, byte_size(value) - 1) <> replacement
  end

  def configure_public_tenant!(tenant_id) do
    tenant = Repo.get!(CommsCore.Administration.Tenant, tenant_id)
    Application.put_env(:comms_core, :instant_rooms_enabled, true)
    Application.put_env(:comms_core, :instant_room_tenant_slug, tenant.slug)
  end

  def restore_env(key, nil), do: Application.delete_env(:comms_core, key)
  def restore_env(key, value), do: Application.put_env(:comms_core, key, value)
  def decode_secret!(value), do: Base.url_decode64!(value, padding: false)
  def sha256(value), do: :crypto.hash(:sha256, value)
end
