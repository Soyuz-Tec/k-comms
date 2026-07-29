defmodule CommsCore.Conversations.EphemeralRooms.RequestTest do
  use ExUnit.Case, async: true

  alias CommsCore.Conversations.EphemeralRooms.Request

  @moduletag :unit

  test "accepts only canonical 32-byte Base64URL authority secrets" do
    {secret, encoded} = Request.generate_token()

    assert byte_size(secret) == 32
    assert byte_size(encoded) == 43
    assert {:ok, ^secret} = Request.idempotency_secret(encoded)
    assert {:ok, ^secret} = Request.token_secret(encoded)

    assert {:error, :invalid_idempotency_key} =
             Request.idempotency_secret(noncanonical_encoding(encoded))

    assert {:error, :invalid_idempotency_key} = Request.idempotency_secret(encoded <> "=")
    assert {:error, :ephemeral_room_unavailable} = Request.token_secret("not-a-token")
  end

  test "normalizes guest-facing input at its documented bounds" do
    longest_name = String.duplicate("a", 120)

    assert {:ok, "Guest"} = Request.display_name("  Guest  ")
    assert {:ok, ^longest_name} = Request.display_name(longest_name)

    assert {:error, :invalid_guest_display_name} =
             Request.display_name(String.duplicate("a", 121))

    assert {:ok, "Instant room"} = Request.room_title(nil)
    assert {:ok, "Instant room"} = Request.room_title("  ")
    assert {:ok, "Planning"} = Request.room_title(" Planning ")

    assert {:error, :invalid_ephemeral_room_title} =
             Request.room_title(String.duplicate("r", 161))

    assert {:ok, %{name: "Browser", platform: "web"}} =
             Request.device(%{"name" => " Browser ", "platform" => " web "})

    assert {:error, :invalid_guest_device} =
             Request.device(%{name: "", platform: "web"})
  end

  test "fingerprints are deterministic and bind identity and device inputs" do
    scope = %{
      tenant_id: Ecto.UUID.generate(),
      owner_kind: :guest
    }

    device = %{name: "Browser", platform: "web"}

    first = Request.create_fingerprint(scope, "Planning", "Guest", device)
    replay = Request.create_fingerprint(scope, "Planning", "Guest", device)
    changed = Request.create_fingerprint(scope, "Planning", "Guest", %{device | name: "Phone"})

    assert Request.secure_match?(first, replay)
    refute Request.secure_match?(first, changed)
    refute Request.secure_match?(first, <<0>>)

    link = %{id: Ecto.UUID.generate()}
    guest = %{account_type: :guest}

    refute Request.secure_match?(
             Request.join_fingerprint(link, guest, "Guest", device),
             Request.join_fingerprint(link, guest, "Different guest", device)
           )
  end

  defp noncanonical_encoding(value) do
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    canonical_last = String.last(value)
    index = :binary.match(alphabet, canonical_last) |> elem(0)
    replacement = String.at(alphabet, index + 1)
    String.slice(value, 0, byte_size(value) - 1) <> replacement
  end
end
