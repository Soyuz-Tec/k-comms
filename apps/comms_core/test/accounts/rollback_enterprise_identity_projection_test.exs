defmodule CommsCore.Accounts.RollbackEnterpriseIdentityProjectionTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Repo, ServiceAccounts}

  alias CommsCore.Accounts.{
    AuthChallenge,
    FederatedIdentity,
    MfaFactor,
    ScimResource,
    Session,
    User
  }

  alias CommsTestSupport.Fixtures

  setup do
    %{owner: Fixtures.account_fixture(), timestamp: DateTime.utc_now()}
  end

  test "legacy password sessions and local password step-up remain rollback compatible", %{
    owner: owner
  } do
    assert Accounts.rollback_enterprise_identity_hazard_count() == 0
    Fixtures.step_up(owner)
    assert Accounts.rollback_enterprise_identity_hazard_count() == 0
  end

  test "pending encrypted enrollment and confirmed MFA proof retain the enterprise boundary", %{
    owner: owner
  } do
    configure_identity_encryption()
    subject = Fixtures.step_up(owner)
    assert {:ok, enrollment} = Accounts.enroll_mfa(subject)
    factor = Repo.get_by!(MfaFactor, user_id: owner.user.id)
    assert is_nil(factor.enabled_at)
    assert byte_size(factor.ciphertext) > 0
    assert Accounts.rollback_enterprise_identity_hazard_count() == 1

    assert {:ok, receipt} =
             Accounts.confirm_mfa(
               NimbleTOTP.verification_code(Base.decode32!(enrollment.secret, padding: false)),
               subject
             )

    assert Accounts.rollback_enterprise_identity_hazard_count() == 2

    # Removing the factor does not erase the active session's stronger proof.
    assert {:ok, _} = Accounts.disable_mfa(hd(receipt.recovery_codes), subject)
    refute Repo.exists?(MfaFactor)
    assert Accounts.rollback_enterprise_identity_hazard_count() == 1
  end

  test "only live unconsumed challenges require the current proof implementation", %{
    owner: owner,
    timestamp: timestamp
  } do
    active = challenge(owner, "mfa_login", timestamp)
    challenge(owner, "oidc", timestamp, user_id: nil)
    challenge(owner, "mfa_login", timestamp, expires_at: DateTime.add(timestamp, -60))
    challenge(owner, "oidc", timestamp, consumed_at: timestamp)
    assert Accounts.rollback_enterprise_identity_hazard_count() == 2

    Repo.update!(Ecto.Changeset.change(active, consumed_at: timestamp))
    assert Accounts.rollback_enterprise_identity_hazard_count() == 1
  end

  test "federation links remain hazards for suspended users and across all tenants", %{
    owner: owner
  } do
    federation(owner, "corporate-subject")
    Repo.update!(Ecto.Changeset.change(Repo.get!(User, owner.user.id), status: :suspended))
    assert Accounts.rollback_enterprise_identity_hazard_count() == 1

    other = Fixtures.account_fixture()
    federation(other, "corporate-subject")
    assert Accounts.rollback_enterprise_identity_hazard_count() == 2
  end

  test "SCIM groups, provisioned users, and retained deprovisioning tombstones block rollback", %{
    owner: owner
  } do
    subject = Fixtures.step_up(owner)

    assert {:ok, credential} =
             ServiceAccounts.create_view(
               %{
                 name: "Rollback directory fixture",
                 scopes: ["scim:read", "scim:write"],
                 reason: "Exercise retained enterprise directory state"
               },
               subject
             )

    assert {:ok, service} = ServiceAccounts.authenticate(credential.credential)

    assert {:ok, group} =
             Accounts.scim_create(
               "Group",
               %{"externalId" => "rollback-group", "displayName" => "Rollback group"},
               service
             )

    assert Accounts.rollback_enterprise_identity_hazard_count() == 1

    assert {:ok, user} =
             Accounts.scim_create(
               "User",
               %{
                 "externalId" => "rollback-user",
                 "userName" => "rollback-user@example.test",
                 "displayName" => "Rollback user"
               },
               service
             )

    assert Accounts.rollback_enterprise_identity_hazard_count() == 2
    assert {:ok, _} = Accounts.scim_delete("User", user.id, user.meta.version, service)
    tombstone = Repo.get!(ScimResource, user.id)
    assert Repo.get!(User, tombstone.user_id).status == :suspended
    assert Accounts.rollback_enterprise_identity_hazard_count() == 2

    assert {:ok, _} = Accounts.scim_delete("Group", group.id, group.meta.version, service)
    assert Accounts.rollback_enterprise_identity_hazard_count() == 1
  end

  test "enhanced sessions remain hazards while the sliding deadline is live and unrevoked", %{
    owner: owner,
    timestamp: timestamp
  } do
    session(owner, timestamp, authentication_method: "oidc")
    session(owner, timestamp, authentication_method: "break_glass")
    session(owner, timestamp, mfa_verified_at: timestamp)
    session(owner, timestamp, authentication_method: "future_enhanced_proof")

    session(owner, timestamp,
      authentication_method: "oidc",
      revoked_at: timestamp
    )

    session(owner, timestamp,
      authentication_method: "break_glass",
      expires_at: DateTime.add(timestamp, -60)
    )

    session(owner, timestamp,
      authentication_method: "break_glass",
      absolute_expires_at: DateTime.add(timestamp, -60)
    )

    session(owner, timestamp,
      mfa_verified_at: timestamp,
      expires_at: DateTime.add(timestamp, -60),
      absolute_expires_at: DateTime.add(timestamp, -60)
    )

    assert Accounts.rollback_enterprise_identity_hazard_count() == 5
  end

  test "an expired break-glass absolute bound cannot certify rollback while sliding expiry is live",
       %{
         owner: owner,
         timestamp: timestamp
       } do
    session(owner, timestamp, absolute_expires_at: DateTime.add(timestamp, -60))
    assert Accounts.rollback_enterprise_identity_hazard_count() == 0

    enhanced =
      session(owner, timestamp,
        authentication_method: "break_glass",
        absolute_expires_at: DateTime.add(timestamp, -60)
      )

    refute Repo.exists?(MfaFactor)
    refute Repo.exists?(FederatedIdentity)
    assert Accounts.rollback_enterprise_identity_hazard_count() == 1

    Repo.update!(Ecto.Changeset.change(enhanced, revoked_at: timestamp))
    assert Accounts.rollback_enterprise_identity_hazard_count() == 0
  end

  defp challenge(owner, kind, timestamp, attrs \\ []) do
    %AuthChallenge{
      tenant_id: owner.tenant.id,
      user_id: owner.user.id,
      kind: kind,
      token_hash: :crypto.strong_rand_bytes(32),
      expires_at: DateTime.add(timestamp, 3600)
    }
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  defp federation(owner, subject) do
    Repo.insert!(%FederatedIdentity{
      tenant_id: owner.tenant.id,
      user_id: owner.user.id,
      issuer: "https://rollback-issuer.example.test",
      subject: subject
    })
  end

  defp session(owner, timestamp, attrs) do
    %Session{
      tenant_id: owner.tenant.id,
      user_id: owner.user.id,
      device_id: owner.device.id,
      refresh_token_hash: :crypto.strong_rand_bytes(32),
      last_used_at: timestamp,
      expires_at: DateTime.add(timestamp, 3600),
      absolute_expires_at: DateTime.add(timestamp, 7200)
    }
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  defp configure_identity_encryption do
    names = [
      :identity_secret_encryption_key,
      :identity_secret_encryption_key_id,
      :identity_secret_encryption_keys
    ]

    previous = Map.new(names, &{&1, Application.get_env(:comms_core, &1)})
    Enum.each(names, &Application.delete_env(:comms_core, &1))
    Application.put_env(:comms_core, :identity_secret_encryption_key, String.duplicate("r", 32))

    on_exit(fn ->
      Enum.each(previous, fn {name, value} ->
        if value,
          do: Application.put_env(:comms_core, name, value),
          else: Application.delete_env(:comms_core, name)
      end)
    end)
  end
end
