defmodule CommsCore.Accounts.EnterpriseMfaTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.{MfaFactor, Session}
  alias CommsTestSupport.Fixtures
  @password "enterprise-fixture-password-4567"

  setup do
    old = Application.get_env(:comms_core, :identity_secret_encryption_key)

    Application.put_env(
      :comms_core,
      :identity_secret_encryption_key,
      "iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii"
    )

    on_exit(fn ->
      if old,
        do: Application.put_env(:comms_core, :identity_secret_encryption_key, old),
        else: Application.delete_env(:comms_core, :identity_secret_encryption_key)
    end)

    owner = Fixtures.account_fixture(%{password: @password})
    subject = Fixtures.subject(owner)
    {:ok, _} = Accounts.step_up_view(%{current_password: @password}, subject)
    %{owner: owner, subject: subject}
  end

  test "enrollment requires recent authentication and independent configured encryption", %{
    owner: owner
  } do
    {:ok, auth} = Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})
    {:ok, context} = Accounts.access_context(auth.session_id)
    assert {:error, :step_up_required} = Accounts.enroll_mfa(context.subject)
    Application.delete_env(:comms_core, :identity_secret_encryption_key)

    assert {:error, :identity_secret_encryption_key_not_configured} =
             Accounts.enroll_mfa(Fixtures.subject(owner))

    refute Repo.exists?(MfaFactor)
  end

  test "real password sign in requires factor, refresh preserves proof, and challenges cannot be replayed",
       %{owner: owner, subject: subject} do
    {:ok, other} = Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})
    {:ok, enrollment} = Accounts.enroll_mfa(subject)
    secret = Base.decode32!(enrollment.secret, padding: false)
    code = NimbleTOTP.verification_code(secret)
    {:ok, receipt} = Accounts.confirm_mfa(code, subject)
    assert length(receipt.recovery_codes) == 10
    assert {:error, :invalid_refresh_token} = Accounts.refresh_session_view(other.refresh_token)

    assert {:error, :mfa_required} =
             Accounts.authenticate_view(owner.tenant.slug, owner.user.email, @password)

    {:ok, challenge} =
      Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})

    assert challenge.mfa_required

    assert {:error, :invalid_mfa_code} =
             Accounts.complete_mfa_sign_in(challenge.challenge_token, code, %{})

    {:ok, authentication} =
      Accounts.complete_mfa_sign_in(challenge.challenge_token, hd(receipt.recovery_codes), %{})

    assert authentication.user.id == owner.user.id
    assert {:ok, rotated} = Accounts.refresh_session_view(authentication.refresh_token)
    assert rotated.session_id == authentication.session_id

    assert {:error, :invalid_mfa_challenge} =
             Accounts.complete_mfa_sign_in(
               challenge.challenge_token,
               Enum.at(receipt.recovery_codes, 1),
               %{}
             )

    {:ok, fresh} = Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})

    assert {:error, :invalid_mfa_code} =
             Accounts.complete_mfa_sign_in(fresh.challenge_token, hd(receipt.recovery_codes), %{})

    factor = Repo.get_by!(MfaFactor, user_id: owner.user.id)
    refute inspect(factor) =~ enrollment.secret
    refute factor.recovery_hashes |> Enum.any?(&(&1 == hd(receipt.recovery_codes)))
    assert length(factor.recovery_hashes) == 9
  end

  test "persisted MFA rate bounds survive failed requests and refresh cannot elevate an unverified session",
       %{owner: owner, subject: subject} do
    {:ok, enrollment} = Accounts.enroll_mfa(subject)
    secret = Base.decode32!(enrollment.secret, padding: false)
    {:ok, _} = Accounts.confirm_mfa(NimbleTOTP.verification_code(secret), subject)

    {:ok, challenge} =
      Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})

    for _ <- 1..5,
        do:
          assert(
            {:error, :invalid_mfa_code} =
              Accounts.complete_mfa_sign_in(challenge.challenge_token, "invalid", %{})
          )

    assert {:error, :mfa_rate_limited} =
             Accounts.complete_mfa_sign_in(challenge.challenge_token, "123456", %{})

    factor = Repo.get_by!(MfaFactor, user_id: owner.user.id)
    assert factor.locked_until

    Repo.update_all(from(s in Session, where: s.id == ^owner.session.id),
      set: [mfa_verified_at: nil]
    )

    assert {:error, :session_expired} = Accounts.access_context(owner.session.id)
    assert {:error, :invalid_refresh_token} = Accounts.refresh_session_view(owner.refresh_token)
    assert {:error, :forbidden} = Accounts.access_grant(subject)

    Repo.update_all(from(s in Session, where: s.id == ^owner.session.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -60)]
    )

    assert {:error, :forbidden} =
             Accounts.step_up_view(%{current_password: @password, mfa_code: "123456"}, subject)
  end

  test "factor changes require step-up plus separate proof and revoke other sessions", %{
    owner: owner,
    subject: subject
  } do
    {:ok, enrollment} = Accounts.enroll_mfa(subject)

    {:ok, receipt} =
      Accounts.confirm_mfa(
        NimbleTOTP.verification_code(Base.decode32!(enrollment.secret, padding: false)),
        subject
      )

    assert {:error, :invalid_mfa_code} =
             Accounts.step_up_view(%{current_password: @password}, subject)

    assert {:error, :invalid_mfa_code} =
             Accounts.change_password_command(
               %{current_password: @password, new_password: "different-secure-password-0987"},
               subject
             )

    {:ok, challenge} =
      Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})

    {:ok, another} =
      Accounts.complete_mfa_sign_in(
        challenge.challenge_token,
        Enum.at(receipt.recovery_codes, 0),
        %{}
      )

    {:ok, _} =
      Accounts.step_up_view(
        %{current_password: @password, mfa_code: Enum.at(receipt.recovery_codes, 1)},
        subject
      )

    {:ok, _} = Accounts.disable_mfa(Enum.at(receipt.recovery_codes, 2), subject)
    assert {:error, :invalid_refresh_token} = Accounts.refresh_session_view(another.refresh_token)
    {:ok, state} = Accounts.identity_security(subject)
    refute state.mfa_enabled

    assert {:ok, _} =
             Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})
  end

  test "password change invalidates pending password-proof challenges before revoking sessions",
       %{owner: owner, subject: subject} do
    {:ok, enrollment} = Accounts.enroll_mfa(subject)

    {:ok, receipt} =
      Accounts.confirm_mfa(
        NimbleTOTP.verification_code(Base.decode32!(enrollment.secret, padding: false)),
        subject
      )

    {:ok, challenge} =
      Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})

    {:ok, _} =
      Accounts.change_password_command(
        %{
          current_password: @password,
          new_password: "changed-enterprise-password-9876",
          mfa_code: hd(receipt.recovery_codes)
        },
        subject
      )

    assert {:error, :invalid_mfa_challenge} =
             Accounts.complete_mfa_sign_in(
               challenge.challenge_token,
               Enum.at(receipt.recovery_codes, 1),
               %{}
             )

    assert {:error, :invalid_credentials} =
             Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})
  end

  test "password recovery invalidates pending challenges while preserving the enrolled factor", %{
    owner: owner,
    subject: subject
  } do
    {:ok, enrollment} = Accounts.enroll_mfa(subject)

    {:ok, receipt} =
      Accounts.confirm_mfa(
        NimbleTOTP.verification_code(Base.decode32!(enrollment.secret, padding: false)),
        subject
      )

    {:ok, challenge} =
      Accounts.password_sign_in(owner.tenant.slug, owner.user.email, @password, %{})

    assert :ok =
             CommsCore.PasswordRecovery.request(%{
               tenant_slug: owner.tenant.slug,
               email: owner.user.email
             })

    request = Repo.get_by!(CommsCore.Accounts.PasswordRecoveryRequest, user_id: owner.user.id)

    {:ok, delivery} =
      CommsCore.PasswordRecovery.materialize_notification(%{
        tenant_id: owner.tenant.id,
        user_id: owner.user.id,
        recovery_request_id: request.id
      })

    token =
      delivery.payload["action_url"]
      |> URI.parse()
      |> Map.fetch!(:fragment)
      |> URI.decode_query()
      |> Map.fetch!("token")

    assert {:ok, _} =
             CommsCore.PasswordRecovery.reset_command(%{
               token: token,
               new_password: "recovered-enterprise-password-9876"
             })

    assert {:error, :invalid_mfa_challenge} =
             Accounts.complete_mfa_sign_in(
               challenge.challenge_token,
               hd(receipt.recovery_codes),
               %{}
             )

    assert Repo.get_by!(MfaFactor, user_id: owner.user.id).enabled_at

    {:ok, fresh} =
      Accounts.password_sign_in(
        owner.tenant.slug,
        owner.user.email,
        "recovered-enterprise-password-9876",
        %{}
      )

    assert {:ok, _} =
             Accounts.complete_mfa_sign_in(fresh.challenge_token, hd(receipt.recovery_codes), %{})
  end
end
