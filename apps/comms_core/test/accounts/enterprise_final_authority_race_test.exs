defmodule CommsCore.Accounts.EnterpriseFinalAuthorityRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo, ServiceAccounts}
  alias CommsCore.Accounts.{AuthChallenge, FederatedIdentity, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Governance.TenantLock
  alias CommsCore.ServiceAccounts.ServiceAccount
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @password "enterprise-authority-race-fixture-1234"

  defmodule Issuer do
    def request(:get, "https://issuer.example.test/.well-known/openid-configuration", _) do
      {:ok,
       %{
         "issuer" => "https://issuer.example.test",
         "authorization_endpoint" => "https://issuer.example.test/authorize",
         "token_endpoint" => "https://issuer.example.test/token",
         "jwks_uri" => "https://issuer.example.test/jwks",
         "response_types_supported" => ["code"],
         "code_challenge_methods_supported" => ["S256"]
       }}
    end

    def request(:post, "https://issuer.example.test/token", _),
      do: {:ok, %{"id_token" => Process.get(:issuer_id_token)}}

    def request(:get, "https://issuer.example.test/jwks", _),
      do: {:ok, %{"keys" => [Process.get(:issuer_public_key)]}}

    def request(:get, url), do: request(:get, url, "")
  end

  test "SCIM and governance erase in canonical User order without a service-user deadlock", %{
    account: account,
    subject: subject
  } do
    {service, resource, managed_user_id} =
      unboxed(fn ->
        {:ok, credential} =
          ServiceAccounts.create_view(
            %{
              name: "Governance race directory",
              scopes: ["scim:read", "scim:write"],
              reason: "Exercise SCIM and governance lock ordering"
            },
            subject
          )

        {:ok, service} = ServiceAccounts.authenticate(credential.credential)
        {:ok, <<service_uuid::unsigned-big-integer-size(128)>>} = Ecto.UUID.dump(service.user_id)

        {:ok, managed_user_id} =
          Ecto.UUID.load(<<service_uuid - 1::unsigned-big-integer-size(128)>>)

        assert managed_user_id < service.user_id

        managed =
          %User{id: managed_user_id}
          |> User.changeset(%{
            tenant_id: account.tenant.id,
            external_subject: "scim:governance-race-user",
            email: "governance-race-#{account.user.id}@example.test",
            display_name: "Governance race managed user",
            role: :member,
            account_type: :human,
            status: :active
          })
          |> Repo.insert!()

        resource =
          Repo.insert!(%CommsCore.Accounts.ScimResource{
            tenant_id: account.tenant.id,
            user_id: managed.id,
            kind: "User",
            external_id: "governance-race-user",
            display_name: managed.display_name
          })

        {:ok, view} = Accounts.scim_get("User", resource.id, service)
        {service, view, managed.id}
      end)

    parent = self()

    eraser =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            # Governance's legal-hold tenant lock precedes every identity row.
            TenantLock.lock!(account.tenant.id)

            Repo.one!(
              from(user in User,
                where: user.id == ^managed_user_id,
                lock: "FOR UPDATE"
              )
            )

            send(parent, {:managed_user_locked, self()})

            receive do
              :erase -> :ok
            after
              10_000 -> raise "governance erasure barrier timed out"
            end

            assert {:ok, _} =
                     Accounts.erase_user_for_governance(%{
                       tenant_id: account.tenant.id,
                       user_id: managed_user_id,
                       pending_deletion_user_ids: [],
                       timestamp: DateTime.utc_now()
                     })

            send(parent, :governance_erased)
            await_commit()
          end)
        end)
      end)

    assert_receive {:managed_user_locked, eraser_pid}, 5_000

    writer =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            send(parent, {:writer_backend, backend_pid()})

            case scim_write(:replace, resource, service) do
              {:error, reason} -> Repo.rollback(reason)
              result -> result
            end
          end)
        end)
      end)

    assert_receive {:writer_backend, writer_backend}, 5_000
    assert_waiting(writer_backend, "users")
    send(eraser_pid, :erase)
    assert_receive :governance_erased, 5_000
    send(eraser_pid, :commit)
    assert {:ok, :ok} = Task.await(eraser, 5_000)
    assert {:error, :not_found} = Task.await(writer, 5_000)

    unboxed(fn ->
      assert Repo.get!(User, managed_user_id).status == :deleted
      assert :ok = ServiceAccounts.authorize_service(service, "scim:write")
    end)
  end

  for wait_reason <- [:tenant_suspension, :challenge_expiry] do
    @wait_reason wait_reason
    test "OIDC sign-in cannot mint a session after #{@wait_reason} during its authority wait", %{
      account: account
    } do
      {start, query, expires_at} =
        unboxed(fn ->
          Repo.insert!(%FederatedIdentity{
            tenant_id: account.tenant.id,
            user_id: account.user.id,
            issuer: "https://issuer.example.test",
            subject: "existing-sign-in-subject"
          })

          {:ok, start} = Accounts.oidc_start(%{tenant_slug: account.tenant.slug}, nil)
          query = URI.decode_query(URI.parse(start.authorization_url).query)
          expires_at = DateTime.add(DateTime.utc_now(), 3, :second)

          if @wait_reason == :challenge_expiry do
            challenge =
              Repo.get_by!(AuthChallenge, token_hash: :crypto.hash(:sha256, query["state"]))

            Repo.update!(Ecto.Changeset.change(challenge, expires_at: expires_at))
          end

          {start, query, expires_at}
        end)

      {token, public_key} = token(query["nonce"], "existing-sign-in-subject")
      parent = self()

      locker =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              case @wait_reason do
                :tenant_suspension ->
                  tenant =
                    Repo.one!(
                      from(tenant in Tenant,
                        where: tenant.id == ^account.tenant.id,
                        lock: "FOR UPDATE"
                      )
                    )

                  Repo.update!(Ecto.Changeset.change(tenant, status: :suspended))

                :challenge_expiry ->
                  Repo.one!(
                    from(user in User, where: user.id == ^account.user.id, lock: "FOR UPDATE")
                  )
              end

              send(parent, {:sign_in_lock, self()})
              await_commit()
            end)
          end)
        end)

      assert_receive {:sign_in_lock, locker_pid}, 5_000

      callback =
        Task.async(fn ->
          unboxed(fn ->
            Process.put(:issuer_id_token, token)
            Process.put(:issuer_public_key, public_key)
            send(parent, {:callback_backend, backend_pid()})

            Accounts.oidc_callback(
              %{state: query["state"], code: "synthetic-code"},
              start.browser_binding,
              nil
            )
          end)
        end)

      assert_receive {:callback_backend, callback_backend}, 5_000

      assert_waiting(
        callback_backend,
        if(@wait_reason == :tenant_suspension, do: "tenants", else: "users")
      )

      if @wait_reason == :challenge_expiry,
        do:
          Process.sleep(max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond) + 25, 0))

      send(locker_pid, :commit)
      assert {:ok, :ok} = Task.await(locker, 5_000)

      expected_error =
        if @wait_reason == :tenant_suspension, do: :forbidden, else: :invalid_oidc_state

      assert {:error, ^expected_error} = Task.await(callback, 5_000)

      unboxed(fn ->
        assert Repo.aggregate(
                 from(session in Session, where: session.user_id == ^account.user.id),
                 :count
               ) == 1
      end)
    end
  end

  test "SCIM rechecks credential expiry after waiting for the managed resource", %{
    account: account,
    subject: subject
  } do
    {service, resource, expires_at} =
      unboxed(fn ->
        {:ok, credential} =
          ServiceAccounts.create_view(
            %{
              name: "Expiring directory",
              scopes: ["scim:read", "scim:write"],
              reason: "Verify expiry after a resource lock wait"
            },
            subject
          )

        {:ok, service} = ServiceAccounts.authenticate(credential.credential)

        {:ok, resource} =
          Accounts.scim_create(
            "User",
            %{
              "externalId" => "expiry-race-user",
              "userName" => "expiry-#{account.user.id}@example.test",
              "displayName" => "Retained after expiry"
            },
            service
          )

        expires_at = DateTime.add(DateTime.utc_now(), 3, :second)
        row = Repo.get!(ServiceAccount, credential.service_account.id)
        Repo.update!(Ecto.Changeset.change(row, expires_at: expires_at))
        {service, resource, expires_at}
      end)

    parent = self()

    locker =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from(resource_row in CommsCore.Accounts.ScimResource,
                where: resource_row.id == ^resource.id,
                lock: "FOR UPDATE"
              )
            )

            send(parent, {:resource_locked, self()})
            await_commit()
          end)
        end)
      end)

    assert_receive {:resource_locked, locker_pid}, 5_000

    writer =
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:writer_backend, backend_pid()})
          scim_write(:replace, resource, service)
        end)
      end)

    assert_receive {:writer_backend, writer_backend}, 5_000
    assert_waiting(writer_backend, "scim_directory_resources")
    Process.sleep(max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond) + 25, 0))
    send(locker_pid, :commit)
    assert {:ok, :ok} = Task.await(locker, 5_000)
    assert {:error, :forbidden} = Task.await(writer, 5_000)

    unboxed(fn ->
      managed = Repo.get_by!(User, tenant_id: account.tenant.id, email: resource.userName)
      assert managed.status == :active
      assert managed.display_name == "Retained after expiry"
    end)
  end

  setup do
    old_oidc = Application.get_env(:comms_core, :oidc)
    old_key = Application.get_env(:comms_core, :identity_secret_encryption_key)
    Application.put_env(:comms_core, :identity_secret_encryption_key, String.duplicate("i", 32))

    Application.put_env(:comms_core, :oidc, %{
      enabled: true,
      issuer: "https://issuer.example.test",
      client_id: "kcomms-test-client",
      client_secret: "synthetic-client-secret-only",
      redirect_uri: "https://app.example.test/sign-in/oidc-callback",
      allowed_redirect_uris: ["https://app.example.test/sign-in/oidc-callback"],
      required_acr_values: ["urn:test:mfa"],
      http_adapter: Issuer
    })

    account =
      unboxed(fn ->
        account = Fixtures.account_fixture(%{password: @password})

        {:ok, _} =
          Accounts.step_up_view(%{current_password: @password}, Fixtures.subject(account))

        account
      end)

    on_exit(fn ->
      restore_env(:oidc, old_oidc)
      restore_env(:identity_secret_encryption_key, old_key)

      unboxed(fn ->
        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("?->>'tenant_id' = ?", job.args, ^account.tenant.id)
          )
        )

        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^account.tenant.id))
      end)
    end)

    %{account: account, subject: Fixtures.subject(account)}
  end

  for authority <- [:session, :device, :user] do
    @authority authority
    test "OIDC link waits for #{@authority} revocation and cannot link after its commit", %{
      account: account,
      subject: subject
    } do
      {:ok, start} =
        unboxed(fn -> Accounts.oidc_start(%{tenant_slug: account.tenant.slug}, subject) end)

      query = URI.decode_query(URI.parse(start.authorization_url).query)
      {token, public_key} = token(query["nonce"], "revoked-link-subject")
      previous_step_up = unboxed(fn -> Repo.get!(Session, account.session.id).step_up_at end)
      parent = self()

      revoker =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              revoke!(@authority, account, subject)
              send(parent, {:revocation_staged, self(), backend_pid()})
              await_commit()
            end)
          end)
        end)

      assert_receive {:revocation_staged, revoker_pid, revoker_backend}, 5_000

      callback =
        Task.async(fn ->
          unboxed(fn ->
            Process.put(:issuer_id_token, token)
            Process.put(:issuer_public_key, public_key)
            send(parent, {:callback_backend, backend_pid()})

            Accounts.oidc_callback(
              %{state: query["state"], code: "synthetic-code"},
              start.browser_binding,
              subject
            )
          end)
        end)

      assert_receive {:callback_backend, callback_backend}, 5_000
      assert_waiting(callback_backend, authority_table(@authority), revoker_backend)
      assert Task.yield(callback, 0) == nil
      send(revoker_pid, :commit)
      assert {:ok, :ok} = Task.await(revoker, 5_000)
      assert {:error, :forbidden} = Task.await(callback, 5_000)

      unboxed(fn ->
        refute Repo.exists?(
                 from(identity in FederatedIdentity, where: identity.user_id == ^account.user.id)
               )

        assert Repo.get!(Session, account.session.id).step_up_at == previous_step_up
      end)
    end
  end

  test "current OIDC and SCIM authorities still commit authorized identity effects", %{
    account: account,
    subject: subject
  } do
    unboxed(fn ->
      {:ok, start} = Accounts.oidc_start(%{tenant_slug: account.tenant.slug}, subject)
      query = URI.decode_query(URI.parse(start.authorization_url).query)
      {token, public_key} = token(query["nonce"], "authorized-link-subject")
      Process.put(:issuer_id_token, token)
      Process.put(:issuer_public_key, public_key)

      assert {:ok, %{linked: true}} =
               Accounts.oidc_callback(
                 %{state: query["state"], code: "synthetic-code"},
                 start.browser_binding,
                 subject
               )

      assert Repo.exists?(
               from(identity in FederatedIdentity,
                 where:
                   identity.user_id == ^account.user.id and
                     identity.subject == "authorized-link-subject"
               )
             )

      {:ok, credential} =
        ServiceAccounts.create_view(
          %{
            name: "Authorized directory",
            scopes: ["scim:read", "scim:write"],
            reason: "Verify current credential success"
          },
          subject
        )

      {:ok, service} = ServiceAccounts.authenticate(credential.credential)

      assert {:ok, resource} =
               Accounts.scim_create(
                 "User",
                 %{
                   "externalId" => "authorized-user",
                   "userName" => "authorized-#{account.user.id}@example.test",
                   "displayName" => "Authorized managed user"
                 },
                 service
               )

      assert {:ok, %{active: false}} =
               Accounts.scim_replace(
                 "User",
                 resource.id,
                 %{"active" => false},
                 resource.meta.version,
                 service
               )
    end)
  end

  for {operation, credential_change} <- [
        {:create, :rotate},
        {:replace, :rotate},
        {:delete, :revoke}
      ] do
    @operation operation
    @credential_change credential_change
    test "SCIM #{@operation} waits for #{@credential_change} and rejects the old credential generation",
         %{
           account: account,
           subject: subject
         } do
      {credential, service, resource, managed_id} =
        unboxed(fn ->
          {:ok, credential} =
            ServiceAccounts.create_view(
              %{
                name: "Race directory",
                scopes: ["scim:read", "scim:write"],
                reason: "Exercise current credential authority"
              },
              subject
            )

          {:ok, service} = ServiceAccounts.authenticate(credential.credential)

          {:ok, resource} =
            Accounts.scim_create(
              "User",
              %{
                "externalId" => "existing-race-user",
                "userName" => "race-user-#{account.user.id}@example.test",
                "displayName" => "Retained managed user"
              },
              service
            )

          managed = Repo.get_by!(User, tenant_id: account.tenant.id, email: resource.userName)
          {credential, service, resource, managed.id}
        end)

      parent = self()

      rotator =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              assert {:ok, _} =
                       change_credential(@credential_change, credential, subject)

              send(parent, {:credential_change_staged, self()})
              await_commit()
            end)
          end)
        end)

      assert_receive {:credential_change_staged, rotator_pid}, 5_000

      writer =
        Task.async(fn ->
          unboxed(fn ->
            send(parent, {:writer_backend, backend_pid()})
            scim_write(@operation, resource, service)
          end)
        end)

      assert_receive {:writer_backend, writer_backend}, 5_000
      assert_waiting(writer_backend, "service_accounts")
      assert Task.yield(writer, 0) == nil
      send(rotator_pid, :commit)
      assert {:ok, :ok} = Task.await(rotator, 5_000)
      assert {:error, :forbidden} = Task.await(writer, 5_000)

      unboxed(fn ->
        assert Repo.get!(User, managed_id).status == :active
        assert Repo.get!(User, managed_id).display_name == "Retained managed user"

        refute Repo.exists?(
                 from(user in User,
                   where:
                     user.tenant_id == ^account.tenant.id and
                       user.external_subject == "scim:rejected-race-user"
                 )
               )
      end)
    end
  end

  defp revoke!(:session, account, _subject),
    do: assert(:ok == Accounts.revoke_session(account.session.id, account.user.id))

  defp revoke!(:device, account, subject),
    do: assert(match?({:ok, _}, Accounts.revoke_device_command(account.device.id, subject)))

  defp revoke!(:user, account, _subject) do
    user = Repo.one!(from(user in User, where: user.id == ^account.user.id, lock: "FOR UPDATE"))
    Repo.update!(Ecto.Changeset.change(user, status: :suspended))
  end

  # Session and Device revocation retain the canonical User lock before their
  # resource locks; the callback must wait on that exact revoker's User row.
  defp authority_table(:session), do: "users"
  defp authority_table(:device), do: "users"
  defp authority_table(:user), do: "users"

  defp change_credential(:rotate, credential, subject),
    do:
      ServiceAccounts.rotate_view(
        credential.service_account.id,
        %{
          version: credential.service_account.version,
          reason: "Rotate during a pending SCIM request"
        },
        subject
      )

  defp change_credential(:revoke, credential, subject),
    do:
      ServiceAccounts.revoke_view(
        credential.service_account.id,
        %{
          version: credential.service_account.version,
          reason: "Revoke during a pending SCIM request"
        },
        subject
      )

  defp scim_write(:create, _resource, service),
    do:
      Accounts.scim_create(
        "User",
        %{
          "externalId" => "rejected-race-user",
          "userName" => "rejected-#{service.tenant_id}@example.test",
          "displayName" => "Rejected managed user"
        },
        service
      )

  defp scim_write(:replace, resource, service),
    do:
      Accounts.scim_replace(
        "User",
        resource.id,
        %{"displayName" => "Unauthorized replacement", "active" => false},
        resource.meta.version,
        service
      )

  defp scim_write(:delete, resource, service),
    do: Accounts.scim_delete("User", resource.id, resource.meta.version, service)

  defp await_commit do
    receive do
      :commit -> :ok
    after
      10_000 -> raise "authority revocation barrier timed out"
    end
  end

  defp assert_waiting(pid, table, blocker_backend \\ nil),
    do: await_row_lock(pid, table, blocker_backend, System.monotonic_time(:millisecond) + 5_000)

  defp await_row_lock(pid, table, blocker_backend, deadline) do
    result =
      unboxed(fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT wait_event_type, query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1",
          [pid]
        )
      end)

    case result.rows do
      [["Lock", query, blockers]] ->
        assert String.contains?(query, ~s(FROM "#{table}"))
        assert String.contains?(query, "FOR ")
        assert blockers != []
        if blocker_backend, do: assert(blocker_backend in blockers)

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("identity effect did not wait for current #{table} authority"),
          else:
            (
              Process.sleep(10)
              await_row_lock(pid, table, blocker_backend, deadline)
            )
    end
  end

  defp backend_pid do
    %{rows: [[pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp token(nonce, subject) do
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = JOSE.JWK.to_public_map(key)
    now = System.system_time(:second)

    {_, token} =
      JOSE.JWT.sign(key, %{"alg" => "RS256", "kid" => "synthetic-key"}, %{
        "iss" => "https://issuer.example.test",
        "sub" => subject,
        "aud" => "kcomms-test-client",
        "nonce" => nonce,
        "auth_time" => now,
        "exp" => now + 300,
        "iat" => now,
        "acr" => "urn:test:mfa"
      })
      |> JOSE.JWS.compact()

    {token, Map.put(public, "kid", "synthetic-key")}
  end

  defp restore_env(key, nil), do: Application.delete_env(:comms_core, key)
  defp restore_env(key, value), do: Application.put_env(:comms_core, key, value)
  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
