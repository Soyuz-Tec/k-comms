defmodule CommsCore.Accounts.SessionsTest do
  use CommsCore.DataCase, async: false

  @moduletag :integration
  @moduletag :session

  alias CommsCore.Accounts

  alias CommsCore.Accounts.{
    AccessContext,
    AuthenticationResult,
    DeviceView,
    Session,
    SessionView,
    User,
    UserView
  }

  alias CommsCore.Administration.{Tenant, TenantView}
  alias CommsCore.Repo
  alias CommsCore.Security.Password
  alias CommsTestSupport.Fixtures

  test "bootstraps a tenant and authenticates its owner" do
    account = Fixtures.account_fixture()

    assert account.tenant.status == :active
    assert account.user.role == :owner
    assert account.conversation.title == "General"
    assert is_binary(account.refresh_token)

    assert {:ok, authenticated} =
             Accounts.authenticate_view(
               account.tenant.slug,
               account.user.email,
               account_fixture_password(account),
               %{name: "Second browser", platform: "test"}
             )

    assert authenticated.user.id == account.user.id
    assert authenticated.device.user_id == account.user.id
    assert {:ok, refreshed} = Accounts.refresh_session(authenticated.refresh_token)
    assert refreshed.session.id == authenticated.session_id
    assert refreshed.refresh_token != authenticated.refresh_token
  end

  test "successful authentication upgrades a legacy password hash" do
    account = Fixtures.account_fixture()
    password = account_fixture_password(account)
    salt = :crypto.strong_rand_bytes(16)
    digest = :crypto.pbkdf2_hmac(:sha256, password, salt, 210_000, 32)

    legacy_hash =
      Enum.join(
        [
          "pbkdf2-sha256",
          "210000",
          Base.url_encode64(salt, padding: false),
          Base.url_encode64(digest, padding: false)
        ],
        "$"
      )

    account.user
    |> Ecto.Changeset.change(password_hash: legacy_hash)
    |> Repo.update!()

    assert {:ok, _authentication} =
             Accounts.authenticate_view(account.tenant.slug, account.user.email, password)

    upgraded_hash = Repo.get!(User, account.user.id).password_hash
    assert Password.verify(password, upgraded_hash)
    refute Password.needs_rehash?(upgraded_hash)
  end

  test "adapter authentication APIs return stable identity contracts" do
    account = Fixtures.account_fixture()

    assert {:ok,
            %AuthenticationResult{
              session_id: session_id,
              tenant: %TenantView{id: tenant_id, status: :active},
              user: %UserView{},
              device: %DeviceView{}
            } = authentication} =
             Accounts.authenticate_view(
               account.tenant.slug,
               account.user.email,
               account_fixture_password(account),
               %{name: "Contract browser", platform: "test"}
             )

    assert tenant_id == account.tenant.id

    for projection <- [
          authentication,
          authentication.tenant,
          authentication.user,
          authentication.device
        ] do
      refute Map.has_key?(Map.from_struct(projection), :__meta__)
    end

    refute function_exported?(Accounts, :authenticate, 3)
    refute function_exported?(Accounts, :authenticate, 4)
    refute function_exported?(Accounts, :list_tenant_users, 1)

    assert {:ok,
            %AccessContext{
              session: %SessionView{id: ^session_id},
              tenant: %TenantView{id: ^tenant_id, status: :active},
              user: %UserView{},
              device: %DeviceView{}
            }} = Accounts.access_context(session_id, "contract-test")
  end

  test "rejects invalid credentials" do
    account = Fixtures.account_fixture()

    assert {:error, :invalid_credentials} =
             Accounts.authenticate_view(
               account.tenant.slug,
               account.user.email,
               "not-the-password"
             )
  end

  @tag :slow
  test "pads current, legacy, and missing-identity authentication failures to one floor" do
    account = Fixtures.account_fixture()
    password = account_fixture_password(account)
    salt = :crypto.strong_rand_bytes(16)
    digest = :crypto.pbkdf2_hmac(:sha256, password, salt, 210_000, 32)

    legacy_hash =
      Enum.join(
        [
          "pbkdf2-sha256",
          "210000",
          Base.url_encode64(salt, padding: false),
          Base.url_encode64(digest, padding: false)
        ],
        "$"
      )

    account.user
    |> Ecto.Changeset.change(password_hash: legacy_hash)
    |> Repo.update!()

    attempts = [
      {account.tenant.slug, account.user.email},
      {account.tenant.slug, "missing-#{account.user.email}"},
      {"missing-#{account.tenant.slug}", account.user.email}
    ]

    for {tenant_slug, email} <- attempts do
      started_at = System.monotonic_time(:millisecond)

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_view(tenant_slug, email, "not-the-password")

      assert System.monotonic_time(:millisecond) - started_at >= 500
    end
  end

  test "tenant inactivity fails closed across sign-in, refresh, and active-session lookup" do
    account = Fixtures.account_fixture()

    account.tenant
    |> Tenant.changeset(%{status: :suspended})
    |> Repo.update!()

    assert {:error, :invalid_credentials} =
             Accounts.authenticate_view(
               account.tenant.slug,
               account.user.email,
               account_fixture_password(account)
             )

    assert {:error, :invalid_refresh_token} = Accounts.refresh_session(account.refresh_token)
    assert {:error, :session_expired} = Accounts.get_active_session(account.session.id)
  end

  @tag :concurrency
  test "a refresh token succeeds only once under concurrent rotation" do
    account = Fixtures.account_fixture()

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Accounts.refresh_session(account.refresh_token) end,
        max_concurrency: 8,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :invalid_refresh_token}, &1)) == 7
    assert {:error, :invalid_refresh_token} = Accounts.refresh_session(account.refresh_token)
  end

  test "the previous release can insert a session without the absolute-expiry column" do
    account = Fixtures.account_fixture()
    session_id = Ecto.UUID.generate()

    inserted_at =
      DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:microsecond)

    expires_at = NaiveDateTime.add(inserted_at, 600, :second)

    assert {:ok, [[true, true]]} =
             Repo.transaction(fn ->
               Ecto.Adapters.SQL.query!(Repo, "SET LOCAL TIME ZONE 'Asia/Kolkata'")

               Ecto.Adapters.SQL.query!(
                 Repo,
                 """
                 INSERT INTO sessions (
                   id, tenant_id, user_id, device_id, refresh_token_hash,
                   expires_at, last_used_at, inserted_at, updated_at
                 )
                 VALUES (
                   $1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, $5,
                   $6::timestamp, $7::timestamp, $7::timestamp, $7::timestamp
                 )
                 RETURNING
                   absolute_expires_at =
                     (CURRENT_TIMESTAMP AT TIME ZONE 'UTC') + INTERVAL '30 days',
                   absolute_expires_at > expires_at
                 """,
                 [
                   session_id,
                   account.tenant.id,
                   account.user.id,
                   account.device.id,
                   :crypto.strong_rand_bytes(32),
                   expires_at,
                   inserted_at
                 ]
               ).rows
             end)

    assert %Session{absolute_expires_at: %DateTime{}} = Repo.get!(Session, session_id)
  end

  test "refresh rotation cannot extend a session beyond its immutable creation lifetime" do
    restore_sliding = preserve_env(:session_ttl_seconds)
    restore_absolute = preserve_env(:session_absolute_ttl_seconds)

    on_exit(fn ->
      restore_sliding.()
      restore_absolute.()
    end)

    Application.put_env(:comms_core, :session_ttl_seconds, 600)
    Application.put_env(:comms_core, :session_absolute_ttl_seconds, 60)

    account = Fixtures.account_fixture()
    absolute_deadline = account.session.absolute_expires_at

    assert DateTime.diff(absolute_deadline, account.session.inserted_at, :second) in 59..60

    changed_deadline = DateTime.add(absolute_deadline, 600, :second)

    refute account.session
           |> Session.changeset(%{absolute_expires_at: changed_deadline})
           |> Map.fetch!(:valid?)

    Application.put_env(:comms_core, :session_absolute_ttl_seconds, 3_600)

    from(session in Session, where: session.id == ^account.session.id)
    |> Repo.update_all(set: [expires_at: DateTime.add(absolute_deadline, 600, :second)])

    assert {:ok, refreshed} = Accounts.refresh_session(account.refresh_token)
    assert refreshed.session.absolute_expires_at == absolute_deadline
    assert refreshed.session.expires_at == absolute_deadline
  end

  test "absolute session expiry rejects refresh and active-session lookup" do
    restore_sliding = preserve_env(:session_ttl_seconds)
    restore_absolute = preserve_env(:session_absolute_ttl_seconds)

    on_exit(fn ->
      restore_sliding.()
      restore_absolute.()
    end)

    Application.put_env(:comms_core, :session_ttl_seconds, 600)
    Application.put_env(:comms_core, :session_absolute_ttl_seconds, 0)

    account = Fixtures.account_fixture()
    assert account.session.expires_at == account.session.absolute_expires_at

    assert {:error, :session_expired} = Accounts.get_active_session(account.session.id)

    assert {:error, :session_expired} =
             Accounts.step_up(
               %{current_password: account_fixture_password(account)},
               Fixtures.subject(account)
             )

    assert {:error, :invalid_refresh_token} = Accounts.refresh_session(account.refresh_token)
  end

  defp account_fixture_password(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()
    "correct-horse-battery-#{suffix}"
  end

  defp preserve_env(key) do
    previous = Application.get_env(:comms_core, key, :not_configured)

    fn ->
      case previous do
        :not_configured -> Application.delete_env(:comms_core, key)
        value -> Application.put_env(:comms_core, key, value)
      end
    end
  end
end
