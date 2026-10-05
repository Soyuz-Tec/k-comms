defmodule CommsCore.Accounts.EnterpriseIdentityKeyRotationTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.{IdentitySecretBox, MfaFactor}
  alias CommsTestSupport.Fixtures
  @password "identity-key-rotation-fixture-password"

  setup do
    names = [
      :identity_secret_encryption_key,
      :identity_secret_encryption_key_id,
      :identity_secret_encryption_keys
    ]

    previous = Map.new(names, &{&1, Application.get_env(:comms_core, &1)})
    Enum.each(names, &Application.delete_env(:comms_core, &1))

    on_exit(fn ->
      Enum.each(previous, fn {name, value} ->
        if value,
          do: Application.put_env(:comms_core, name, value),
          else: Application.delete_env(:comms_core, name)
      end)
    end)

    ring = %{
      "old" => Base.encode64(String.duplicate("o", 32)),
      "new" => Base.encode64(String.duplicate("n", 32))
    }

    Application.put_env(:comms_core, :identity_secret_encryption_keys, ring)
    Application.put_env(:comms_core, :identity_secret_encryption_key_id, "old")
    %{ring: ring}
  end

  test "old factors decrypt across rotation while new enrollment uses the active key and missing old material fails closed",
       %{ring: ring} do
    owner = Fixtures.account_fixture(%{password: @password})
    {:ok, _} = Accounts.step_up_view(%{current_password: @password}, Fixtures.subject(owner))
    {:ok, old_enrollment} = Accounts.enroll_mfa(Fixtures.subject(owner))

    {:ok, recovery} =
      Accounts.confirm_mfa(
        NimbleTOTP.verification_code(Base.decode32!(old_enrollment.secret, padding: false)),
        Fixtures.subject(owner)
      )

    old_factor = Repo.get_by!(MfaFactor, user_id: owner.user.id)
    assert old_factor.key_id == "old"
    Application.put_env(:comms_core, :identity_secret_encryption_key_id, "new")

    assert {:ok, old_secret} =
             IdentitySecretBox.decrypt(Map.from_struct(old_factor), context(old_factor))

    assert old_secret == Base.decode32!(old_enrollment.secret, padding: false)
    other = Fixtures.account_fixture(%{password: @password})
    {:ok, _} = Accounts.step_up_view(%{current_password: @password}, Fixtures.subject(other))
    {:ok, _} = Accounts.enroll_mfa(Fixtures.subject(other))
    assert Repo.get_by!(MfaFactor, user_id: other.user.id).key_id == "new"
    Application.put_env(:comms_core, :identity_secret_encryption_keys, Map.take(ring, ["new"]))

    assert {:error, :identity_secret_encryption_key_unavailable} =
             IdentitySecretBox.decrypt(Map.from_struct(old_factor), context(old_factor))

    {:ok, challenge} =
      Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})

    assert {:error, :identity_secret_encryption_key_unavailable} =
             Accounts.complete_mfa_sign_in(
               challenge.challenge_token,
               hd(recovery.recovery_codes),
               %{}
             )

    Application.put_env(:comms_core, :identity_secret_encryption_keys, ring)

    assert {:ok, authentication} =
             Accounts.complete_mfa_sign_in(
               challenge.challenge_token,
               hd(recovery.recovery_codes),
               %{}
             )

    assert authentication.user.id == owner.user.id
  end

  test "ciphertext and authentication tags cannot be moved across tenants, factors, versions, or key IDs" do
    context = %{
      tenant_id: Ecto.UUID.generate(),
      identity_secret_id: Ecto.UUID.generate(),
      version: 1
    }

    {:ok, encrypted} = IdentitySecretBox.encrypt("synthetic-factor-secret", context)

    for changed <- [
          %{context | tenant_id: Ecto.UUID.generate()},
          %{context | identity_secret_id: Ecto.UUID.generate()},
          %{context | version: 2}
        ] do
      assert {:error, :identity_secret_decryption_failed} =
               IdentitySecretBox.decrypt(encrypted, changed)
    end

    assert {:error, :identity_secret_decryption_failed} =
             IdentitySecretBox.decrypt(%{encrypted | key_id: "new"}, context)

    <<first, rest::binary>> = encrypted.tag

    assert {:error, :identity_secret_decryption_failed} =
             IdentitySecretBox.decrypt(
               %{encrypted | tag: <<Bitwise.bxor(first, 1), rest::binary>>},
               context
             )

    assert {:ok, "synthetic-factor-secret"} = IdentitySecretBox.decrypt(encrypted, context)
  end

  defp context(factor),
    do: %{tenant_id: factor.tenant_id, identity_secret_id: factor.id, version: 1}
end
