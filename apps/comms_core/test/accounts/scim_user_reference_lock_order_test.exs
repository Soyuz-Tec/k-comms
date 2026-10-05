defmodule CommsCore.Accounts.ScimUserReferenceLockOrderTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, Repo, ServiceAccounts, Telephony}
  alias CommsCore.Accounts.{Device, ScimResource, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Security.Password
  alias CommsCore.Telephony.{Call, Mailbox, Number, Voicemail, VoicemailRead}
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @password "scim-user-reference-password-1234"

  for operation <- [:deactivate, :delete] do
    @operation operation

    test "SCIM #{operation} permits a Session-retaining voicemail read to complete its User FK" do
      fixture = fixture()
      parent = self()

      reader =
        actor(
          parent,
          :reader,
          fn -> Telephony.mark_voicemail_read(fixture.voicemail.id, fixture.reader_subject) end,
          barrier: fn query ->
            String.contains?(query, ~s(FROM "sessions")) and
              String.contains?(query, "FOR SHARE")
          end
        )

      assert_receive {:reader_backend, reader_backend}, 5_000
      assert_receive {:reader_barrier, reader_pid, release}, 5_000

      writer = actor(parent, :writer, fn -> deprovision(@operation, fixture) end, trace: true)
      assert_receive {:writer_backend, writer_backend}, 5_000
      {query, blockers} = wait_for_lock(writer_backend)
      assert String.contains?(query, ~s(UPDATE "sessions"))
      assert reader_backend in blockers

      trace = query_trace()

      managed_lock =
        Enum.find_index(trace, fn {query, params} ->
          String.contains?(query, ~s(FROM "users")) and
            String.contains?(query, "FOR NO KEY UPDATE") and
            Enum.any?(params, &bound_uuid?(&1, fixture.reader.user.id))
        end)

      resource_lock =
        Enum.find_index(trace, fn {query, params} ->
          String.contains?(query, ~s(FROM "scim_directory_resources")) and
            String.contains?(query, "FOR UPDATE") and
            Enum.any?(params, &bound_uuid?(&1, fixture.resource.id)) and
            Enum.any?(params, &bound_uuid?(&1, fixture.owner.tenant.id))
        end)

      assert is_integer(managed_lock), "exact managed User NK lock was not traced"
      assert is_integer(resource_lock), "exact SCIM directory resource UPDATE lock was not traced"
      assert managed_lock < resource_lock

      refute Enum.any?(trace, fn {query, _params} ->
               String.contains?(query, ~s(FROM "users")) and String.contains?(query, "FOR UPDATE")
             end)

      send(reader_pid, {:release_barrier, release})
      assert {:ok, %{read_at: %DateTime{}}} = Task.await(reader, 10_000)
      assert {:ok, result} = Task.await(writer, 10_000)
      assert fixture.reader.session.id in result.revoked_session_ids

      unboxed(fn ->
        assert Repo.get_by!(VoicemailRead,
                 voicemail_id: fixture.voicemail.id,
                 user_id: fixture.reader.user.id
               ).read_at

        assert Repo.get!(Session, fixture.reader.session.id).revoked_at
        assert Repo.get!(User, fixture.reader.user.id).status == :suspended
        assert Repo.get!(User, fixture.reader.user.id).role == :member
        assert Repo.get!(ScimResource, fixture.resource.id).lock_version == 2
        assert Repo.get!(Voicemail, fixture.voicemail.id).status == :available
        assert Repo.get!(Call, fixture.voicemail.call_id).cleanup_completed_at

        assert {:error, :forbidden} =
                 Telephony.mark_voicemail_read(fixture.voicemail.id, fixture.reader_subject)
      end)
    end
  end

  test "public same-target SCIM writers serialize on their actual quota lock and reject stale etags" do
    fixture = fixture()
    parent = self()

    first =
      actor(
        parent,
        :first,
        fn ->
          Accounts.scim_replace(
            "User",
            fixture.resource.id,
            %{"displayName" => "First current directory name"},
            fixture.resource.meta.version,
            fixture.service
          )
        end,
        barrier: fn query ->
          String.contains?(query, "pg_advisory_xact_lock")
        end
      )

    assert_receive {:first_backend, first_backend}, 5_000
    assert_receive {:first_barrier, first_pid, release}, 5_000

    second =
      actor(parent, :second, fn ->
        Accounts.scim_delete(
          "User",
          fixture.resource.id,
          fixture.resource.meta.version,
          fixture.service
        )
      end)

    assert_receive {:second_backend, second_backend}, 5_000
    {query, blockers} = wait_for_lock(second_backend)
    assert String.contains?(query, "pg_advisory_xact_lock")
    assert first_backend in blockers

    # The public entry points already serialize before retaining target Users;
    # this verifies the real prefix, rather than inventing a Resource/User race.
    send(first_pid, {:release_barrier, release})
    assert {:ok, updated} = Task.await(first, 10_000)
    assert updated.meta.version != fixture.resource.meta.version
    assert {:error, :stale_version} = Task.await(second, 10_000)

    unboxed(fn ->
      assert Repo.get!(User, fixture.reader.user.id).display_name ==
               "First current directory name"

      assert Repo.get!(User, fixture.reader.user.id).status == :active
      refute Repo.get!(Session, fixture.reader.session.id).revoked_at
      assert Repo.get!(ScimResource, fixture.resource.id).lock_version == 2

      assert Repo.aggregate(
               from(event in AuditEvent,
                 where:
                   event.tenant_id == ^fixture.owner.tenant.id and
                     event.resource_id == ^fixture.resource.id and
                     event.action in ["identity.scim_updated", "identity.scim_deprovisioned"]
               ),
               :count
             ) == 1
    end)
  end

  defp fixture do
    fixture =
      unboxed(fn ->
        owner = Fixtures.account_fixture()
        register_cleanup(owner.tenant.id)
        subject = Fixtures.step_up(owner)

        {:ok, credential} =
          ServiceAccounts.create_view(
            %{
              name: "SCIM current User reference",
              scopes: ["scim:read", "scim:write"],
              reason: "Exercise current directory deprovisioning"
            },
            subject
          )

        {:ok, service} = ServiceAccounts.authenticate(credential.credential)

        {:ok, resource} =
          Accounts.scim_create(
            "User",
            %{
              "externalId" => "vm-user-" <> owner.user.id,
              "userName" => "vm-user-#{owner.user.id}@example.test",
              "displayName" => "Managed voicemail reader"
            },
            service
          )

        user =
          Repo.get_by!(User, tenant_id: owner.tenant.id, email: resource.userName)
          |> Ecto.Changeset.change(password_hash: Password.hash(@password))
          |> Repo.update!()

        {:ok, authentication} =
          Accounts.authenticate_view(owner.tenant.slug, user.email, @password, %{})

        session = Repo.get!(Session, authentication.session_id)
        device = Repo.get!(Device, session.device_id)
        reader = %{owner | user: user, session: session, device: device}

        %{
          owner: owner,
          service: service,
          credential: credential,
          resource: resource,
          reader: reader,
          reader_subject: Fixtures.subject(reader),
          voicemail: available_voicemail(reader)
        }
      end)

    fixture
  end

  defp register_cleanup(tenant_id) do
    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          event_ids =
            Repo.all(
              from(event in OutboxEvent, where: event.tenant_id == ^tenant_id, select: event.id)
            )

          voicemail_ids =
            Repo.all(
              from(voicemail in Voicemail,
                where: voicemail.tenant_id == ^tenant_id,
                select: voicemail.id
              )
            )

          call_ids =
            Repo.all(from(call in Call, where: call.tenant_id == ^tenant_id, select: call.id))

          service_ids =
            Repo.all(
              from(service in CommsCore.ServiceAccounts.ServiceAccount,
                where: service.tenant_id == ^tenant_id,
                select: service.id
              )
            )

          Repo.delete_all(
            from(job in Oban.Job,
              where:
                fragment("?->>'tenant_id' = ?", job.args, ^tenant_id) or
                  fragment("?->>'event_id' = ANY(?::text[])", job.args, ^event_ids) or
                  fragment("?->>'voicemail_id' = ANY(?::text[])", job.args, ^voicemail_ids) or
                  fragment("?->>'call_id' = ANY(?::text[])", job.args, ^call_ids) or
                  fragment("?->>'service_account_id' = ANY(?::text[])", job.args, ^service_ids)
            )
          )

          # These tables intentionally use restrictive tenant and media FKs.
          # Remove only this fixture's children before its Tenant cascade.
          Repo.delete_all(from(read in VoicemailRead, where: read.tenant_id == ^tenant_id))
          Repo.delete_all(from(voicemail in Voicemail, where: voicemail.tenant_id == ^tenant_id))
          Repo.delete_all(from(mailbox in Mailbox, where: mailbox.tenant_id == ^tenant_id))
          Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^tenant_id))
        end)
      end)
    end)
  end

  defp available_voicemail(account) do
    now = DateTime.utc_now()
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

    number =
      %Number{}
      |> Number.changeset(%{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        phone_number: "+1" <> String.pad_leading(suffix, 10, "0"),
        extension: "101",
        inbound_trunk_id: "ST_inbound",
        outbound_trunk_id: "ST_outbound"
      })
      |> Repo.insert!()

    box =
      %Mailbox{}
      |> Mailbox.changeset(%{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        number_id: number.id,
        enabled: false,
        retention_days: 30,
        notice_media: "sound:custom/synthetic-notice"
      })
      |> Repo.insert!()

    call =
      %Call{}
      |> Call.changeset(%{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        number_id: number.id,
        inbound_trunk_id: number.inbound_trunk_id,
        outbound_trunk_id: number.outbound_trunk_id,
        direction: :inbound,
        status: :ended,
        from_number: "+14155550200",
        to_number: number.phone_number,
        extension: number.extension,
        provider_room: "scim-fk-room-" <> suffix,
        provider_identity: "scim-fk-caller-" <> suffix,
        started_at: DateTime.add(now, -60, :second),
        answered_at: DateTime.add(now, -50, :second),
        ended_at: DateTime.add(now, -10, :second),
        end_reason: "caller_ended",
        expires_at: DateTime.add(now, 60, :second),
        cleanup_completed_at: now
      })
      |> Repo.insert!()

    %Voicemail{}
    |> Voicemail.changeset(%{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      mailbox_id: box.id,
      call_id: call.id,
      recording_name: "scim_fk_" <> suffix,
      notice_media: box.notice_media,
      status: :available,
      recording_deadline: DateTime.add(now, 60, :second),
      retention_expires_at: DateTime.add(now, 86_400, :second),
      available_at: now,
      provider_deleted_at: now,
      duration_seconds: 2,
      byte_size: 32,
      object_key: "synthetic/scim-fk-" <> suffix,
      object_version_id: "exact-fixture-version",
      object_etag: "exact-fixture-etag",
      checksum_sha256: String.duplicate("a", 64),
      verified_checksum_sha256: String.duplicate("a", 64)
    })
    |> Repo.insert!()
  end

  defp deprovision(:deactivate, fixture),
    do:
      Accounts.scim_replace(
        "User",
        fixture.resource.id,
        %{"active" => false},
        fixture.resource.meta.version,
        fixture.service
      )

  defp deprovision(:delete, fixture),
    do:
      Accounts.scim_delete(
        "User",
        fixture.resource.id,
        fixture.resource.meta.version,
        fixture.service
      )

  defp bound_uuid?(value, uuid), do: value == uuid or Ecto.UUID.dump(uuid) == {:ok, value}

  defp query_trace(acc \\ []) do
    receive do
      {:writer_query, query, params} -> query_trace([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp actor(parent, label, operation, opts \\ []) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})
          if matcher = Keyword.get(opts, :barrier), do: attach_barrier(parent, label, matcher)
          trace = if Keyword.get(opts, :trace), do: attach_trace(parent)

          try do
            operation.()
          after
            if trace, do: :telemetry.detach(trace)
          end
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp attach_trace(parent) do
    handler = {__MODULE__, :trace, make_ref()}
    actor = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comms_core, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == actor,
            do: send(parent, {:writer_query, metadata.query, metadata.params || []})
        end,
        nil
      )

    handler
  end

  defp attach_barrier(parent, label, matcher) do
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
            send(parent, {String.to_atom("#{label}_barrier"), self(), release})

            receive do
              {:release_barrier, ^release} -> :ok
            after
              12_000 -> raise "SCIM User-reference query barrier timed out"
            end
          end
        end,
        nil
      )
  end

  defp wait_for_lock(backend, attempts \\ 300)
  defp wait_for_lock(_backend, 0), do: flunk("actor did not reach an actual database lock wait")

  defp wait_for_lock(backend, attempts) do
    case unboxed(fn ->
           Repo.query!(
             "SELECT query, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND cardinality(pg_blocking_pids(pid)) > 0",
             [backend]
           ).rows
         end) do
      [[query, blockers]] ->
        {query, blockers}

      [] ->
        Process.sleep(10)
        wait_for_lock(backend, attempts - 1)
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
