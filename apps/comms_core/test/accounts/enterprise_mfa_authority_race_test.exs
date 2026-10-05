defmodule CommsCore.Accounts.EnterpriseMfaAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.{Device, IdentitySecretBox, MfaFactor, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @password "mfa-authority-race-password-1234"
  @changed_password "mfa-authority-replacement-password-9876"

  setup do
    previous = Application.get_env(:comms_core, :identity_secret_encryption_key)
    Application.put_env(:comms_core, :identity_secret_encryption_key, String.duplicate("i", 32))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comms_core, :identity_secret_encryption_key, previous),
        else: Application.delete_env(:comms_core, :identity_secret_encryption_key)
    end)

    :ok
  end

  for operation <- [:enroll, :confirm, :disable, :rotate, :step_up, :change_password],
      revocation <- [:session, :device] do
    @operation operation
    @revocation revocation

    test "#{operation} cannot mutate after a committed #{@revocation} revocation" do
      context = fixture(@operation)
      before = unboxed(fn -> persisted_state(context) end)
      parent = self()

      actor =
        Task.async(fn ->
          attach_barrier(parent, :authority_read, &authority_read?/1)
          unboxed(fn -> invoke(@operation, context) end)
        end)

      assert_receive {:authority_read, pid, release}, 5_000

      assert {:ok, _} =
               unboxed(fn ->
                 case @revocation do
                   :session ->
                     Accounts.revoke_session(context.account.session.id, context.account.user.id)
                     |> then(fn result -> if result == :ok, do: {:ok, :revoked}, else: result end)

                   :device ->
                     Accounts.revoke_device_command(context.account.device.id, context.subject)
                 end
               end)

      send(pid, {:release_barrier, release})
      assert {:error, :forbidden} = Task.await(actor, 10_000)

      unboxed(fn ->
        after_state = persisted_state(context)
        assert after_state.factor == before.factor
        assert after_state.password_hash == before.password_hash
        assert after_state.step_up_at == before.step_up_at

        if @revocation == :session,
          do: assert(after_state.session_revoked_at),
          else: assert(Repo.get!(Device, context.account.device.id).revoked_at)
      end)
    end
  end

  test "factor rotation cannot mutate after current human status changes" do
    context = fixture(:rotate)
    before = unboxed(fn -> persisted_state(context) end)
    parent = self()

    actor =
      Task.async(fn ->
        attach_barrier(parent, :authority_read, &authority_read?/1)
        unboxed(fn -> invoke(:rotate, context) end)
      end)

    assert_receive {:authority_read, pid, release}, 5_000

    # This is a separate committed canonical identity mutation, deliberately
    # leaving the session intact to prove the current User fence itself.
    assert {1, _} =
             unboxed(fn ->
               Repo.update_all(from(user in User, where: user.id == ^context.account.user.id),
                 set: [status: :suspended]
               )
             end)

    send(pid, {:release_barrier, release})
    assert {:error, :forbidden} = Task.await(actor, 10_000)
    assert unboxed(fn -> persisted_state(context).factor end) == before.factor
  end

  for operation <- [:disable, :rotate, :step_up, :change_password] do
    @operation operation

    test "#{operation} holds its original factor proof through effect and cannot alter a replacement" do
      context = fixture(@operation)
      parent = self()

      actor =
        Task.async(fn ->
          attach_barrier(parent, :factor_proved, fn query ->
            String.contains?(query, ~s(UPDATE "identity_mfa_factors"))
          end)

          unboxed(fn -> invoke(@operation, context) end)
        end)

      assert_receive {:factor_proved, pid, release}, 5_000

      fresh_id = Ecto.UUID.generate()
      fresh_hash = :crypto.hash(:sha256, "replacement-only-code-" <> fresh_id)

      replacement =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
              send(parent, {:replacement_backend, backend})

              # Real replacement follows the owning User→factor order. The
              # in-flight effect must keep it outside the proof/mutation gap.
              Repo.one!(
                from(user in User,
                  where: user.id == ^context.account.user.id,
                  lock: "FOR UPDATE"
                )
              )

              if factor =
                   Repo.one(
                     from(factor in MfaFactor,
                       where: factor.user_id == ^context.account.user.id,
                       lock: "FOR UPDATE"
                     )
                   ),
                 do: Repo.delete!(factor)

              {:ok, encrypted} =
                IdentitySecretBox.encrypt(NimbleTOTP.secret(), %{
                  tenant_id: context.account.tenant.id,
                  identity_secret_id: fresh_id,
                  version: 1
                })

              Repo.insert!(
                struct!(
                  MfaFactor,
                  Map.merge(encrypted, %{
                    id: fresh_id,
                    tenant_id: context.account.tenant.id,
                    user_id: context.account.user.id,
                    enabled_at: DateTime.utc_now(),
                    recovery_hashes: [fresh_hash]
                  })
                )
              )
            end)
          end)
        end)

      assert_receive {:replacement_backend, backend}, 5_000
      waiting_query = wait_for_lock(backend)
      assert String.contains?(waiting_query, ~s(FROM "users"))

      send(pid, {:release_barrier, release})
      assert {:ok, _} = Task.await(actor, 10_000)
      assert {:ok, _} = Task.await(replacement, 10_000)

      unboxed(fn ->
        replacement_factor = Repo.get_by!(MfaFactor, user_id: context.account.user.id)
        assert replacement_factor.id == fresh_id
        assert replacement_factor.enabled_at
        assert replacement_factor.recovery_hashes == [fresh_hash]

        # Old consumed proof cannot subsequently mutate the new factor or grant
        # another step-up/password change, even on the still-live current session.
        before = persisted_state(context)
        assert {:error, :invalid_mfa_code} = invoke(@operation, context)
        after_state = persisted_state(context)
        assert after_state.factor.id == fresh_id
        assert after_state.factor.recovery_hashes == [fresh_hash]
        assert after_state.password_hash == before.password_hash
        assert after_state.step_up_at == before.step_up_at
      end)
    end
  end

  test "failed privileged and password-factor proofs persist rate state without effects" do
    context = fixture(:rotate)
    before = unboxed(fn -> persisted_state(context) end)

    unboxed(fn ->
      for operation <- [:disable, :rotate, :step_up, :change_password] do
        assert {:error, :invalid_mfa_code} = invoke(operation, %{context | code: "invalid"})
      end

      after_state = persisted_state(context)
      assert after_state.factor.failed_attempts == 4
      assert after_state.factor.recovery_hashes == before.factor.recovery_hashes
      assert after_state.factor.enabled_at == before.factor.enabled_at
      assert after_state.password_hash == before.password_hash
      assert after_state.step_up_at == before.step_up_at
      refute after_state.session_revoked_at
    end)
  end

  for operation <- [:step_up, :change_password] do
    @operation operation

    test "#{operation} with a wrong password consumes successful recovery proof without a credential effect" do
      context = fixture(@operation)

      unboxed(fn ->
        before = persisted_state(context)

        attrs = %{
          current_password: "wrong-current-password",
          new_password: @changed_password,
          mfa_code: context.code
        }

        result =
          case @operation do
            :step_up -> Accounts.step_up_view(attrs, context.subject)
            :change_password -> Accounts.change_password_command(attrs, context.subject)
          end

        assert {:error, :invalid_current_password} = result
        after_state = persisted_state(context)
        refute :crypto.hash(:sha256, context.code) in after_state.factor.recovery_hashes
        assert after_state.password_hash == before.password_hash
        assert after_state.step_up_at == before.step_up_at
        assert {:error, :invalid_mfa_code} = invoke(@operation, context)
      end)
    end
  end

  defp fixture(operation) do
    context =
      unboxed(fn ->
        account = Fixtures.account_fixture(%{password: @password})
        subject = Fixtures.subject(account)
        {:ok, _} = Accounts.step_up_view(%{current_password: @password}, subject)

        code =
          if operation != :enroll do
            {:ok, enrollment} = Accounts.enroll_mfa(subject)
            totp = NimbleTOTP.verification_code(Base.decode32!(enrollment.secret, padding: false))

            if operation == :confirm do
              totp
            else
              {:ok, receipt} = Accounts.confirm_mfa(totp, subject)
              hd(receipt.recovery_codes)
            end
          end

        %{account: account, subject: subject, code: code}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^context.account.tenant.id))
      end)
    end)

    context
  end

  defp invoke(:enroll, context), do: Accounts.enroll_mfa(context.subject)
  defp invoke(:confirm, context), do: Accounts.confirm_mfa(context.code, context.subject)
  defp invoke(:disable, context), do: Accounts.disable_mfa(context.code, context.subject)
  defp invoke(:rotate, context), do: Accounts.rotate_mfa_recovery(context.code, context.subject)

  defp invoke(:step_up, context),
    do:
      Accounts.step_up_view(
        %{current_password: @password, mfa_code: context.code},
        context.subject
      )

  defp invoke(:change_password, context),
    do:
      Accounts.change_password_command(
        %{
          current_password: @password,
          new_password: @changed_password,
          mfa_code: context.code
        },
        context.subject
      )

  defp persisted_state(context) do
    user = Repo.get!(User, context.account.user.id)
    session = Repo.get!(Session, context.account.session.id)
    factor = Repo.get_by(MfaFactor, tenant_id: user.tenant_id, user_id: user.id)

    %{
      factor:
        if(factor,
          do:
            Map.take(factor, [
              :id,
              :enabled_at,
              :recovery_hashes,
              :last_used_step,
              :failed_attempts
            ])
        ),
      password_hash: user.password_hash,
      step_up_at: session.step_up_at,
      session_revoked_at: session.revoked_at
    }
  end

  defp authority_read?(query) do
    String.contains?(query, ~s(FROM "sessions")) or
      (String.contains?(query, ~s(FROM "tenants")) and String.contains?(query, "FOR SHARE"))
  end

  defp attach_barrier(parent, event, matcher) do
    handler = {__MODULE__, make_ref()}
    release = make_ref()
    actor = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comms_core, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == actor and matcher.(metadata.query) do
            :telemetry.detach(handler)
            send(parent, {event, self(), release})

            receive do
              {:release_barrier, ^release} -> :ok
            after
              10_000 -> raise "MFA authority query barrier timed out"
            end
          end
        end,
        nil
      )
  end

  defp wait_for_lock(backend, attempts \\ 200)
  defp wait_for_lock(_backend, 0), do: flunk("replacement did not reach an actual database lock")

  defp wait_for_lock(backend, attempts) do
    case unboxed(fn ->
           Repo.query!(
             "SELECT query FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0",
             [backend]
           ).rows
         end) do
      [[query]] ->
        query

      [] ->
        Process.sleep(10)
        wait_for_lock(backend, attempts - 1)
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
