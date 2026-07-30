defmodule CommsCore.Conversations.GuestAccess.TokenTest do
  use ExUnit.Case, async: true

  alias CommsCore.Conversations.GuestAccess.Token

  @moduletag :unit
  @moduletag :conversation
  @moduletag :guest

  test "parses only canonical link identifiers with 32-byte secrets" do
    link_id = Ecto.UUID.generate()
    secret = :crypto.strong_rand_bytes(32)
    encoded = Base.url_encode64(secret, padding: false)
    short_encoded = Base.url_encode64(:crypto.strong_rand_bytes(31), padding: false)

    assert {:ok, ^link_id, ^secret} = Token.parse(link_id <> "." <> encoded)
    assert {:error, :guest_link_unavailable} = Token.parse(link_id <> "." <> short_encoded)
    assert {:error, :guest_link_unavailable} = Token.parse("not-a-link")
  end

  test "verification digests bind every authority component" do
    tenant_id = Ecto.UUID.generate()
    conversation_id = Ecto.UUID.generate()
    link_id = Ecto.UUID.generate()
    email = "guest@example.test"

    {code, digest} =
      Token.conversion_verification_credentials(
        email,
        :crypto.strong_rand_bytes(32),
        tenant_id,
        conversation_id,
        link_id
      )

    assert {true, secret} = Token.conversion_verification_secret(code)

    assert Token.secure_binary_match?(
             digest,
             Token.conversion_verification_digest(
               secret,
               tenant_id,
               conversation_id,
               link_id,
               email
             )
           )

    refute Token.secure_binary_match?(
             digest,
             Token.conversion_verification_digest(
               secret,
               tenant_id,
               conversation_id,
               Ecto.UUID.generate(),
               email
             )
           )
  end

  test "normalizes conversion emails and exposes only a bounded hint" do
    assert Token.normalize_email(" Guest@Example.TEST ") == "guest@example.test"
    assert Token.valid_conversion_email?("guest@example.test")
    refute Token.valid_conversion_email?("guest@service.invalid")
    assert Token.email_hint("guest@example.test") == "g***@example.test"
  end
end
