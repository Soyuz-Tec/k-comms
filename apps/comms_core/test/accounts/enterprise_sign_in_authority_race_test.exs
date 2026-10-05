defmodule CommsCore.Accounts.EnterpriseSignInAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.{AuthChallenge, Device, MfaFactor, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @password "sign-in-authority-race-password-1234"
  @break_glass_secret String.duplicate("b", 32)

  setup do
    previous_key = Application.get_env(:comms_core, :identity_secret_encryption_key)
    previous_recovery = Application.get_env(:comms_core, :identity_break_glass_secret)
    Application.put_env(:comms_core, :identity_secret_encryption_key, String.duplicate("i", 32))
    Application.put_env(:comms_core, :identity_break_glass_secret, @break_glass_secret)

    on_exit(fn ->
      restore(:identity_secret_encryption_key, previous_key)
      restore(:identity_break_glass_secret, previous_recovery)
    end)

    :ok
  end

  for wait_on <- [:user, :challenge, :factor, :device] do
    @wait_on wait_on

    test "a MFA challenge that expires during a real #{wait_on} lock wait cannot mint credentials" do
      context = fixture(true)

      {challenge, before, row, expiry} =
        unboxed(fn ->
          attrs =
            if @wait_on == :device,
              do: %{
                id: context.account.device.id,
                name: "Existing login device",
                platform: "test"
              },
              else: %{name: "Fresh challenge device", platform: "test"}

          {:ok, response} =
            Accounts.password_sign_in(
              context.account.tenant.slug,
              context.account.user.email,
              @password,
              attrs
            )

          challenge =
            Repo.get_by!(AuthChallenge,
              token_hash: :crypto.hash(:sha256, response.challenge_token)
            )

          expiry = DateTime.add(DateTime.utc_now(), 3, :second)
          challenge = Repo.update!(Ecto.Changeset.change(challenge, expires_at: expiry))

          row =
            case @wait_on do
              :user ->
                {User, context.account.user.id, ~s(FROM "users")}

              :challenge ->
                {AuthChallenge, challenge.id, ~s(FROM "identity_auth_challenges")}

              :factor ->
                {MfaFactor, Repo.get_by!(MfaFactor, user_id: context.account.user.id).id,
                 ~s(FROM "identity_mfa_factors")}

              :device ->
                {Device, context.account.device.id, ~s(UPDATE "devices")}
            end

          {Map.put(response, :id, challenge.id), footprint(context), row, expiry}
        end)

      parent = self()
      {schema, row_id, expected_query} = row

      holder =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.one!(from(value in schema, where: value.id == ^row_id, lock: "FOR UPDATE"))
              send(parent, {:row_locked, self()})

              receive do
                :release_row -> :ok
              after
                10_000 -> raise "sign-in row holder timed out"
              end
            end)
          end)
        end)

      on_exit(fn -> if Process.alive?(holder.pid), do: Process.exit(holder.pid, :kill) end)
      assert_receive {:row_locked, holder_pid}, 5_000

      actor =
        Task.async(fn ->
          unboxed(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
            send(parent, {:login_backend, backend})
            Accounts.complete_mfa_sign_in(challenge.challenge_token, context.code, %{})
          end)
        end)

      on_exit(fn -> if Process.alive?(actor.pid), do: Process.exit(actor.pid, :kill) end)
      assert_receive {:login_backend, backend}, 5_000
      assert String.contains?(wait_for_lock(backend), expected_query)
      wait_for_expiry(expiry)
      send(holder_pid, :release_row)

      assert {:ok, :ok} = Task.await(holder, 5_000)
      assert {:error, :invalid_mfa_challenge} = Task.await(actor, 5_000)

      unboxed(fn ->
        assert footprint(context) == before
        stored = Repo.get!(AuthChallenge, challenge.id)
        refute stored.consumed_at
        assert stored.attempts == 0

        # Expiry rejected before acceptance; its otherwise-unused recovery code
        # remains valid for a newly issued, current challenge.
        {:ok, fresh} =
          Accounts.password_sign_in(
            context.account.tenant.slug,
            context.account.user.email,
            @password,
            %{}
          )

        assert {:ok, auth} =
                 Accounts.complete_mfa_sign_in(fresh.challenge_token, context.code, %{})

        assert auth.user.id == context.account.user.id

        assert {:error, :invalid_mfa_challenge} =
                 Accounts.complete_mfa_sign_in(challenge.challenge_token, context.code, %{})
      end)
    end
  end

  for operation <- [:password_sign_in, :password_sign_in_mfa, :authenticate_view, :break_glass] do
    @operation operation

    test "#{operation} cannot issue credentials after tenant suspension commits following password verification" do
      context = fixture(@operation in [:password_sign_in_mfa, :break_glass])
      before = unboxed(fn -> footprint(context) end)
      parent = self()

      actor =
        Task.async(fn ->
          attach_verified_tenant_barrier(parent)
          unboxed(fn -> invoke(@operation, context) end)
        end)

      assert_receive {:tenant_verified, pid, release}, 5_000

      assert {1, _} =
               unboxed(fn ->
                 Repo.update_all(
                   from(tenant in Tenant, where: tenant.id == ^context.account.tenant.id),
                   set: [status: :suspended]
                 )
               end)

      send(pid, {:release_barrier, release})

      expected =
        if @operation == :break_glass,
          do: :invalid_break_glass_credentials,
          else: :invalid_credentials

      assert {:error, ^expected} = Task.await(actor, 10_000)
      assert unboxed(fn -> footprint(context) end) == before
    end
  end

  defp fixture(mfa?) do
    context =
      unboxed(fn ->
        account = Fixtures.account_fixture(%{password: @password})
        subject = Fixtures.subject(account)
        {:ok, _} = Accounts.step_up_view(%{current_password: @password}, subject)

        code =
          if mfa? do
            {:ok, enrollment} = Accounts.enroll_mfa(subject)

            {:ok, receipt} =
              Accounts.confirm_mfa(
                NimbleTOTP.verification_code(Base.decode32!(enrollment.secret, padding: false)),
                subject
              )

            hd(receipt.recovery_codes)
          end

        %{account: account, code: code}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^context.account.tenant.id))
      end)
    end)

    context
  end

  defp invoke(:password_sign_in_mfa, context), do: invoke(:password_sign_in, context)

  defp invoke(:password_sign_in, context),
    do:
      Accounts.password_sign_in(
        context.account.tenant.slug,
        context.account.user.email,
        @password,
        %{name: "Tenant fenced sign-in", platform: "test"}
      )

  defp invoke(:authenticate_view, context),
    do:
      Accounts.authenticate_view(
        context.account.tenant.slug,
        context.account.user.email,
        @password,
        %{name: "Tenant fenced legacy sign-in", platform: "test"}
      )

  defp invoke(:break_glass, context),
    do:
      Accounts.break_glass_session(%{
        tenant_slug: context.account.tenant.slug,
        email: context.account.user.email,
        password: @password,
        mfa_code: context.code,
        credential_token: @break_glass_secret,
        actor: "Custodial operator fixture",
        reason: "Authorized synthetic recovery test"
      })

  defp footprint(context) do
    user_id = context.account.user.id
    factor = Repo.get_by(MfaFactor, user_id: user_id)

    %{
      sessions:
        Repo.aggregate(from(session in Session, where: session.user_id == ^user_id), :count),
      devices: Repo.aggregate(from(device in Device, where: device.user_id == ^user_id), :count),
      challenges:
        Repo.aggregate(
          from(challenge in AuthChallenge, where: challenge.user_id == ^user_id),
          :count
        ),
      factor:
        if(factor,
          do: Map.take(factor, [:id, :recovery_hashes, :last_used_step, :failed_attempts])
        ),
      device:
        Repo.get!(Device, context.account.device.id)
        |> Map.take([:last_seen_at, :revoked_at, :name])
    }
  end

  defp attach_verified_tenant_barrier(parent) do
    handler = {__MODULE__, make_ref()}
    release = make_ref()
    actor = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comms_core, :repo, :query],
        fn _, _, metadata, _ ->
          query = metadata.query
          # This is the final unlocked active-tenant read in verify_identity, after
          # real password verification, before credential-issuing row locks.
          if self() == actor and String.contains?(query, ~s(FROM "tenants")) and
               String.contains?(query, ~s("id" = $1)) and not String.contains?(query, "FOR SHARE") do
            :telemetry.detach(handler)
            send(parent, {:tenant_verified, self(), release})

            receive do
              {:release_barrier, ^release} -> :ok
            after
              10_000 -> raise "verified tenant query barrier timed out"
            end
          end
        end,
        nil
      )
  end

  defp wait_for_lock(backend, attempts \\ 200)
  defp wait_for_lock(_backend, 0), do: flunk("login did not reach an actual database lock")

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

  defp wait_for_expiry(expiry) do
    if DateTime.compare(DateTime.utc_now(), expiry) == :lt do
      Process.sleep(10)
      wait_for_expiry(expiry)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:comms_core, key)
  defp restore(key, value), do: Application.put_env(:comms_core, key, value)
  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
