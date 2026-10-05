defmodule CommsCore.Accounts.EnterprisePasswordRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.{AuthChallenge, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  @moduletag :integration
  @moduletag :concurrency
  @password "verified-password-race-fixture-1234"
  @changed_password "replacement-password-race-fixture-9876"

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

  for {operation, mfa_enabled?, legacy_hash?} <- [
        {:password_sign_in, false, false},
        {:password_sign_in, true, false},
        {:authenticate_view, false, false},
        {:authenticate_view, false, true}
      ] do
    @operation operation
    @mfa_enabled? mfa_enabled?
    @legacy_hash? legacy_hash?
    test "#{operation} with MFA=#{mfa_enabled?}, legacy hash=#{legacy_hash?} cannot mint credentials from a password changed after the identity read" do
      account =
        unboxed(fn ->
          owner = Fixtures.account_fixture(%{password: @password})

          if @legacy_hash? do
            # The same standard PBKDF2 fixture used by sessions_test.exs exercises
            # the real compare-and-swap rehash path during the credential race.
            salt = :crypto.strong_rand_bytes(16)
            digest = :crypto.pbkdf2_hmac(:sha256, @password, salt, 210_000, 32)

            hash =
              Enum.join(
                [
                  "pbkdf2-sha256",
                  "210000",
                  Base.url_encode64(salt, padding: false),
                  Base.url_encode64(digest, padding: false)
                ],
                "$"
              )

            Repo.update_all(from(user in User, where: user.id == ^owner.user.id),
              set: [password_hash: hash]
            )
          end

          if @mfa_enabled? do
            subject = Fixtures.subject(owner)
            {:ok, _} = Accounts.step_up_view(%{current_password: @password}, subject)
            {:ok, enrollment} = Accounts.enroll_mfa(subject)

            {:ok, receipt} =
              Accounts.confirm_mfa(
                NimbleTOTP.verification_code(Base.decode32!(enrollment.secret, padding: false)),
                subject
              )

            Map.put(owner, :factor_code, hd(receipt.recovery_codes))
          else
            owner
          end
        end)

      on_exit(fn ->
        unboxed(fn ->
          Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^account.tenant.id))
        end)
      end)

      parent = self()
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:comms_core, :repo, :query],
          fn _, _, metadata, _ ->
            # The first identity query has already returned the old committed row.
            # Pausing the caller here exercises real password verification with that
            # snapshot, followed by its current-user lock, without a production hook.
            if String.contains?(metadata.query, ~s(FROM "users")) and
                 String.contains?(metadata.query, "lower(") do
              send(parent, {:identity_read, self()})

              receive do
                :continue -> :ok
              after
                5_000 -> raise "password identity-read barrier timed out"
              end
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      reader =
        Task.async(fn ->
          unboxed(fn ->
            apply(Accounts, @operation, [account.tenant.slug, account.user.email, @password, %{}])
          end)
        end)

      assert_receive {:identity_read, pid}, 5_000

      assert {:ok, _} =
               unboxed(fn ->
                 Accounts.change_password_command(
                   %{
                     current_password: @password,
                     new_password: @changed_password,
                     mfa_code: Map.get(account, :factor_code)
                   },
                   Fixtures.subject(account)
                 )
               end)

      send(pid, :continue)
      assert {:error, :invalid_credentials} = Task.await(reader, 5_000)

      unboxed(fn ->
        assert Repo.aggregate(
                 from(session in Session, where: session.user_id == ^account.user.id),
                 :count
               ) == 1

        refute Repo.exists?(
                 from(challenge in AuthChallenge, where: challenge.user_id == ^account.user.id)
               )
      end)
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
