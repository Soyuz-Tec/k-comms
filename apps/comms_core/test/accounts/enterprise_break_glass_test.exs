defmodule CommsCore.Accounts.EnterpriseBreakGlassTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.{MfaFactor, Session}
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Security.Password
  alias CommsTestSupport.Fixtures
  @password "emergency-owner-fixture-password-123"
  @credential "synthetic-console-recovery-credential-only"

  setup do
    old_secret = Application.get_env(:comms_core, :identity_break_glass_secret)
    old_key = Application.get_env(:comms_core, :identity_secret_encryption_key)
    Application.delete_env(:comms_core, :identity_break_glass_secret)
    Application.put_env(:comms_core, :identity_secret_encryption_key, String.duplicate("i", 32))

    on_exit(fn ->
      for {key, value} <- [
            identity_break_glass_secret: old_secret,
            identity_secret_encryption_key: old_key
          ] do
        if value,
          do: Application.put_env(:comms_core, key, value),
          else: Application.delete_env(:comms_core, key)
      end
    end)

    owner = Fixtures.account_fixture(%{password: @password})

    attrs = %{
      credential_token: @credential,
      actor: "Recovery operator",
      reason: "Corporate provider outage drill",
      tenant_slug: owner.tenant.slug,
      email: owner.user.email,
      password: @password
    }

    %{owner: owner, attrs: attrs}
  end

  test "emergency access defaults off and cannot promote a member or replace credentials", %{
    owner: owner,
    attrs: attrs
  } do
    assert {:error, :invalid_break_glass_credentials} = Accounts.break_glass_session(attrs)
    Application.put_env(:comms_core, :identity_break_glass_secret, @credential)

    assert {:error, :invalid_break_glass_credentials} =
             Accounts.break_glass_session(%{attrs | credential_token: "wrong"})

    assert {:error, :invalid_break_glass_credentials} =
             Accounts.break_glass_session(%{attrs | password: "wrong"})

    member = Fixtures.user_fixture(owner, %{password_hash: Password.hash(@password)}).user

    assert {:error, :invalid_break_glass_credentials} =
             Accounts.break_glass_session(%{attrs | email: member.email})

    refute Repo.exists?(
             from(event in AuditEvent, where: event.action == "identity.break_glass_used")
           )
  end

  test "attributed recovery session has an immutable fifteen-minute deadline across refresh", %{
    owner: owner,
    attrs: attrs
  } do
    Application.put_env(:comms_core, :identity_break_glass_secret, @credential)
    assert {:ok, auth} = Accounts.break_glass_session(attrs)
    assert auth.user.id == owner.user.id
    session = Repo.get!(Session, auth.session_id)
    assert session.authentication_method == "break_glass"
    assert DateTime.diff(session.absolute_expires_at, session.inserted_at) in 899..901
    deadline = session.absolute_expires_at
    assert {:ok, _} = Accounts.refresh_session_view(auth.refresh_token)
    assert Repo.get!(Session, session.id).absolute_expires_at == deadline
    audit = Repo.get_by!(AuditEvent, action: "identity.break_glass_used", resource_id: session.id)
    assert audit.metadata["operator"] == attrs.actor
    assert audit.metadata["reason"] == attrs.reason
    assert audit.metadata["alert_required"] == true
    refute inspect(audit.metadata) =~ @credential
  end

  test "emergency recovery requires an enrolled factor and cannot consume a code twice", %{
    owner: owner,
    attrs: attrs
  } do
    subject = Fixtures.subject(owner)
    {:ok, _} = Accounts.step_up_view(%{current_password: @password}, subject)
    {:ok, enrollment} = Accounts.enroll_mfa(subject)

    {:ok, receipt} =
      Accounts.confirm_mfa(
        NimbleTOTP.verification_code(Base.decode32!(enrollment.secret, padding: false)),
        subject
      )

    Application.put_env(:comms_core, :identity_break_glass_secret, @credential)
    assert {:error, :invalid_break_glass_credentials} = Accounts.break_glass_session(attrs)
    recovery = hd(receipt.recovery_codes)
    assert {:ok, _} = Accounts.break_glass_session(Map.put(attrs, :mfa_code, recovery))

    assert {:error, :invalid_break_glass_credentials} =
             Accounts.break_glass_session(Map.put(attrs, :mfa_code, recovery))

    assert Repo.get_by!(MfaFactor, user_id: owner.user.id).enabled_at
  end
end
