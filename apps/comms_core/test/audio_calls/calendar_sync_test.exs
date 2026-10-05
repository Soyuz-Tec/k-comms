defmodule CommsCore.AudioCalls.CalendarSyncTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query
  @moduletag :integration
  @moduletag :call
  alias CommsCore.{Administration, AudioCalls, Repo}
  alias CommsCore.Administration.TenantSettings

  alias CommsCore.AudioCalls.CalendarSync.{
    Budget,
    Boxes,
    CallbackCommand,
    Connection,
    Connections,
    EventMapping,
    EventReceipt,
    ErasureReceipt,
    Export,
    ExternalIdentityReceipt,
    IdentityFenceCommand,
    ProviderCapability,
    SyncCommand,
    TokenReceipt
  }

  alias CommsTestSupport.Fixtures

  defmodule Provider do
    @behaviour CommsCore.AudioCalls.CalendarSync.ProviderPort
    def status(provider), do: %ProviderCapability{provider: provider, configured?: true}

    def authorization_url(provider, state, _nonce, _verifier),
      do:
        {:ok,
         "https://accounts.google.com/o/oauth2/v2/auth?" <>
           URI.encode_query(%{state: state, provider: provider})}

    def token(request) do
      send(self(), {:calendar_refresh_or_exchange, request.operation})

      Process.get(
        :calendar_test_token,
        {:ok,
         %TokenReceipt{
           provider: request.provider,
           access_token: "synthetic-access",
           refresh_token: "synthetic-refresh",
           identity: %ExternalIdentityReceipt{
             provider: request.provider,
             external_subject: "same-principal",
             oidc_subject: "same-sub"
           },
           expires_at: DateTime.add(DateTime.utc_now(), 3600),
           scopes: []
         }}
      )
    end

    def event(command) do
      send(self(), {:calendar_effect, command.operation, command.marker_id})
      outcome = Process.get(:calendar_test_outcome, :applied)

      {:ok,
       %EventReceipt{
         provider: command.provider,
         outcome: outcome,
         external_id: if(outcome in [:applied, :present], do: "managed-synthetic-id"),
         etag: if(outcome in [:applied, :present], do: "synthetic-etag")
       }}
    end

    def revoke(provider, _token, _deadline),
      do: {:ok, if(provider == :microsoft, do: :external_unconfirmed, else: :confirmed)}
  end

  setup do
    keys = [:calendar_provider_adapter, :calendar_secret_keyring, :calendar_workspace_origin]
    previous = Map.new(keys, &{&1, Application.get_env(:comms_core, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_core, key),
          else: Application.put_env(:comms_core, key, value)
      end)
    end)

    Application.put_env(:comms_core, :calendar_provider_adapter, Provider)

    Application.put_env(:comms_core, :calendar_secret_keyring, %{
      current_key_id: "test",
      keys: %{"test" => :crypto.strong_rand_bytes(32)}
    })

    Application.put_env(:comms_core, :calendar_workspace_origin, "https://workspace.example.test")
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    assert {:ok, initial} = Administration.get_tenant_settings(subject)
    refute initial.settings.allow_calendar_export

    assert {:ok, enabled} =
             Administration.update_tenant_settings(
               %{version: initial.settings.lock_version, allow_calendar_export: true},
               subject
             )

    assert enabled.settings.allow_calendar_export

    assert enabled.settings.calendar_export_policy_version ==
             initial.settings.calendar_export_policy_version + 1

    assert {:error, :stale_version} =
             Administration.update_tenant_settings(
               %{version: initial.settings.lock_version, allow_calendar_export: false},
               subject
             )

    connection = connection(account)
    {:ok, meeting} = AudioCalls.schedule_meeting(account.conversation.id, input(), subject)
    {:ok, account: account, subject: subject, connection: connection, meeting: meeting}
  end

  test "explicit opt-in retains the occurrence marker across source edits and fences cancellation",
       context do
    assert Repo.aggregate(Export, :count) == 0

    assert {:error, :stale_version} =
             AudioCalls.create_calendar_export(export_input(context, 2), context.subject)

    assert {:ok, export} =
             AudioCalls.create_calendar_export(export_input(context, 1), context.subject)

    mapping = Repo.get_by!(EventMapping, export_id: export.id)

    assert {:ok, edited} =
             AudioCalls.update_meeting(
               context.meeting.id,
               Map.put(input(), :expected_version, 1),
               context.subject
             )

    retained = Repo.get!(EventMapping, mapping.id)
    assert retained.desired_meeting_version == edited.version
    assert is_nil(retained.tombstoned_at)

    assert {:ok, _} =
             AudioCalls.cancel_meeting(
               edited.id,
               %{expected_version: edited.version},
               context.subject
             )

    assert Repo.get!(EventMapping, mapping.id).tombstoned_at
    assert Repo.get!(Export, export.id).status == :stopping
  end

  test "unknown create acknowledgement is reconciled without a blind second create", context do
    {:ok, export} = AudioCalls.create_calendar_export(export_input(context, 1), context.subject)
    command = Repo.get_by!(SyncCommand, export_id: export.id, operation: :create)
    Process.put(:calendar_test_outcome, :uncertain)
    assert {:ok, :uncertain} = perform(command)
    assert_receive {:calendar_effect, :create, marker}

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(SyncCommand, command.id),
        available_at: DateTime.add(Budget.now(), -1)
      )
    )

    Process.put(:calendar_test_outcome, :absent)
    assert {:ok, :absent} = perform(command)
    assert_receive {:calendar_effect, :reconcile, ^marker}
    refute_receive {:calendar_effect, :create, _}
    assert Repo.get!(Export, export.id).status == :conflict
  end

  test "known-object 404 does not complete cleanup until scoped reconciliation", context do
    {export, command} = exported(context)
    assert {:ok, _} = perform(command)
    current = Repo.get!(Connection, context.connection.id)

    assert {:ok, _} =
             AudioCalls.unlink_calendar_connection(
               current.id,
               %{version: current.version},
               context.subject
             )

    cleanup =
      Repo.get_by!(SyncCommand,
        export_id: export.id,
        operation: :reconcile,
        consent_generation: 2
      )

    Process.put(:calendar_test_outcome, :absent)
    assert {:ok, :removal_pending_verification} = perform(cleanup)
    assert_receive {:calendar_effect, :delete, _}
    mapping = Repo.get_by!(EventMapping, export_id: export.id)
    assert is_nil(mapping.verified_at)

    assert {:ok, true} =
             AudioCalls.calendar_governance_erasure_pending?(
               context.account.tenant.id,
               :user,
               context.account.user.id
             )

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(SyncCommand, cleanup.id),
        available_at: DateTime.add(Budget.now(), -1)
      )
    )

    assert {:ok, :verified_absent} = perform(cleanup)
    assert_receive {:calendar_effect, :reconcile, _}

    revoke =
      Repo.get_by!(SyncCommand,
        connection_id: current.id,
        operation: :revoke,
        consent_generation: 2
      )

    assert {:ok, :local_credentials_destroyed} = perform(revoke)

    assert {:ok, false} =
             AudioCalls.calendar_governance_erasure_pending?(
               context.account.tenant.id,
               :user,
               context.account.user.id
             )

    assert {:ok, {:ok, _}} =
             Repo.transaction(fn ->
               AudioCalls.prepare_calendar_governance_erasure(
                 context.account.tenant.id,
                 :user,
                 context.account.user.id
               )
             end)

    refute Repo.get(Connection, current.id)
    refute Repo.get(Export, export.id)
    refute Repo.get(EventMapping, mapping.id)

    receipt =
      Repo.get_by!(ErasureReceipt, tenant_id: context.account.tenant.id, target_type: :user)

    assert receipt.status == :verified
    assert receipt.version == 2

    assert {:ok, {:ok, plan}} =
             Repo.transaction(fn ->
               AudioCalls.prepare_calendar_governance_erasure(
                 context.account.tenant.id,
                 :user,
                 context.account.user.id
               )
             end)

    assert plan.pending_export_count == 0
    assert plan.pending_connection_count == 0
    assert Repo.get!(ErasureReceipt, receipt.id).version == 3
  end

  test "expired grant refresh failure retains tokens and blocks completion", context do
    {_export, command} = exported(context)
    old = context.connection.credentials_box

    Repo.update!(
      Ecto.Changeset.change(context.connection,
        access_expires_at: DateTime.add(Budget.now(), -60)
      )
    )

    Process.put(:calendar_test_token, {:error, :invalid_calendar_token})
    assert {:ok, :reauthorization_required} = perform(command)
    current = Repo.get!(Connection, context.connection.id)
    assert current.credentials_box == old
    assert current.fenced_at
    assert current.status == :reauthorization_required
    assert Repo.get!(SyncCommand, command.id).status == :blocked
    refute_receive {:calendar_effect, _, _}

    assert {:ok, true} =
             AudioCalls.calendar_governance_erasure_pending?(
               context.account.tenant.id,
               :user,
               context.account.user.id
             )
  end

  test "User-held local fence does not require Governance/provider and logout preserves offline consent",
       context do
    command =
      CommsCore.Accounts.CallLifecycleCommand.sessions_revoked(
        context.account.tenant.id,
        [context.account.session.id],
        "logout"
      )

    assert {:ok, {:ok, _}} =
             Repo.transaction(fn ->
               CommsCore.AudioCalls.LifecycleCoordinator.revoke_identity_access(command)
             end)

    assert Repo.get!(Connection, context.connection.id).status == :ready
    Application.put_env(:comms_core, :calendar_provider_adapter, :unavailable_provider)

    assert {:ok, {:ok, receipt}} =
             Repo.transaction(fn ->
               Repo.one!(
                 from(u in CommsCore.Accounts.User,
                   where:
                     u.tenant_id == ^context.account.tenant.id and
                       u.id == ^context.account.user.id,
                   lock: "FOR NO KEY UPDATE"
                 )
               )

               AudioCalls.fence_calendar_identity(%IdentityFenceCommand{
                 tenant_id: context.account.tenant.id,
                 user_id: context.account.user.id,
                 reason: :workspace_scope_withdrawn,
                 deadline_ms: Budget.deadline()
               })
             end)

    assert receipt.fenced_connection_count == 1
    assert Repo.get!(Connection, context.connection.id).consent_generation == 2
  end

  test "cleanup reauthorization binds the same principal without enabling new exports", context do
    {export, _} = exported(context)

    {:ok, _} =
      AudioCalls.unlink_calendar_connection(context.connection.id, %{version: 1}, context.subject)

    tombstone = Repo.get!(Export, export.id).tombstoned_at

    {:ok, authorization} =
      AudioCalls.begin_calendar_authorization(
        :google,
        %{export_policy_version: context.connection.export_policy_version, purpose: "cleanup"},
        context.subject
      )

    state = URI.decode_query(URI.parse(authorization.authorization_url).query)["state"]

    assert {:ok, view} =
             AudioCalls.complete_calendar_authorization(%CallbackCommand{
               provider: :google,
               state: state,
               code: "synthetic-code",
               browser_binding: authorization.browser_binding
             })

    assert view.status == :removing
    refute view.new_exports_allowed?
    assert view.consent_generation == 2
    assert Repo.get!(Export, export.id).tombstoned_at == tombstone

    assert {:error, :calendar_export_disabled} =
             AudioCalls.create_calendar_export(export_input(context, 1), context.subject)

    assert {:error, :calendar_callback_rejected} =
             AudioCalls.complete_calendar_authorization(%CallbackCommand{
               provider: :google,
               state: state,
               code: "synthetic-code",
               browser_binding: authorization.browser_binding
             })
  end

  test "cleanup reauthorization refuses a different external principal without replacing retained material",
       context do
    {export, _} = exported(context)

    {:ok, _} =
      AudioCalls.unlink_calendar_connection(context.connection.id, %{version: 1}, context.subject)

    retained = Repo.get!(Connection, context.connection.id)

    {:ok, authorization} =
      AudioCalls.begin_calendar_authorization(
        :google,
        %{export_policy_version: context.connection.export_policy_version, purpose: "cleanup"},
        context.subject
      )

    state = URI.decode_query(URI.parse(authorization.authorization_url).query)["state"]

    Process.put(
      :calendar_test_token,
      {:ok,
       %TokenReceipt{
         provider: :google,
         access_token: "different-access",
         refresh_token: "different-refresh",
         identity: %ExternalIdentityReceipt{
           provider: :google,
           external_subject: "different-principal",
           oidc_subject: "different-sub"
         },
         expires_at: DateTime.add(DateTime.utc_now(), 3600),
         scopes: []
       }}
    )

    callback = %CallbackCommand{
      provider: :google,
      state: state,
      code: "synthetic-code",
      browser_binding: authorization.browser_binding
    }

    assert {:error, :calendar_cleanup_principal_mismatch} =
             AudioCalls.complete_calendar_authorization(callback)

    current = Repo.get!(Connection, retained.id)
    assert current.credentials_box == retained.credentials_box
    assert current.external_identity_box == retained.external_identity_box
    assert current.consent_generation == retained.consent_generation
    assert current.fenced_at == retained.fenced_at
    assert Repo.get!(Export, export.id).tombstoned_at

    assert {:error, :calendar_callback_rejected} =
             AudioCalls.complete_calendar_authorization(callback)

    refute_receive {:calendar_effect, _, _}
  end

  test "Microsoft unconfirmed grant revocation remains pending after local destruction",
       context do
    connection = connection(context.account, :microsoft)

    {:ok, _} =
      AudioCalls.unlink_calendar_connection(connection.id, %{version: 1}, context.subject)

    revoke = Repo.get_by!(SyncCommand, connection_id: connection.id, operation: :revoke)
    assert {:ok, :local_credentials_destroyed} = perform(revoke)
    current = Repo.get!(Connection, connection.id)
    assert is_nil(current.credentials_box)
    assert current.provider_grant_revocation == :external_unconfirmed

    assert {:ok, true} =
             AudioCalls.calendar_governance_erasure_pending?(
               context.account.tenant.id,
               :user,
               context.account.user.id
             )
  end

  defp connection(account, provider \\ :google) do
    settings = Repo.get_by!(TenantSettings, tenant_id: account.tenant.id)

    connection =
      Repo.insert!(%Connection{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        provider: provider,
        export_policy_version: settings.calendar_export_policy_version
      })

    Repo.update!(
      Ecto.Changeset.change(connection,
        status: :ready,
        access_expires_at: DateTime.add(Budget.now(), 3600),
        credentials_box:
          Boxes.encrypt!(
            %{access_token: "synthetic-access", refresh_token: "synthetic-refresh"},
            Connections.secret_context(connection, connection.id, :credential)
          ),
        external_identity_box:
          Boxes.encrypt!(
            %{external_subject: "same-principal", oidc_subject: "same-sub"},
            Connections.secret_context(connection, connection.id, :external_identity)
          )
      )
    )
  end

  defp input,
    do: %{
      title: "Synthetic hosted meeting",
      timezone: "Etc/UTC",
      local_start:
        DateTime.add(DateTime.utc_now(), 3600)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)
        |> NaiveDateTime.to_iso8601(),
      duration_minutes: 30,
      reminder_minutes: 15,
      recurrence: %{frequency: "none", interval: 1, count: 1},
      host_policy: %{allow_guests: false, join_before_host: false}
    }

  defp export_input(context, version),
    do: %{
      connection_id: context.connection.id,
      meeting_id: context.meeting.id,
      meeting_version: version
    }

  defp exported(context) do
    {:ok, export} = AudioCalls.create_calendar_export(export_input(context, 1), context.subject)
    {export, Repo.get_by!(SyncCommand, export_id: export.id, operation: :create)}
  end

  defp perform(command),
    do:
      AudioCalls.perform_calendar_command(
        command.id,
        command.consent_generation,
        CommsWorkers.CalendarSyncWorker
      )
end
