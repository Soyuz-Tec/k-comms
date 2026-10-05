defmodule CommsCore.Accounts.GovernanceIdentityDrainLockOrderTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Repo, Telephony}
  alias CommsCore.Accounts.{Device, GovernanceErasureCommand, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Events.OutboxEvent
  alias CommsCore.Telephony.{Call, Mailbox, Number, Voicemail, VoicemailRead}
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @moduletag :governance

  for rollback <- [false, true] do
    @rollback rollback

    test "governed identity drains a real Session/FK reader before key anonymization; outer rollback #{@rollback}" do
      fixture = fixture()
      parent = self()

      reader =
        actor(
          parent,
          :reader,
          fn ->
            Telephony.mark_voicemail_read(fixture.voicemail.id, Fixtures.subject(fixture.account))
          end,
          barrier: fn query ->
            String.contains?(query, ~s(FROM "sessions")) and
              String.contains?(query, "FOR SHARE")
          end
        )

      assert_receive {:reader_backend, reader_backend}, 5_000
      assert_receive {:reader_barrier, reader_pid, release}, 5_000

      eraser =
        actor(parent, :eraser, fn ->
          Repo.transaction(fn ->
            # These are the actual existing owner operations used by Governance.
            # The authorization fence must not upgrade User before Session drain.
            assert :ok =
                     Accounts.ensure_governance_erasure_allowed(
                       fixture.account.tenant.id,
                       fixture.account.user.id,
                       []
                     )

            assert {:ok, receipt} =
                     Accounts.erase_user_for_governance(%{
                       tenant_id: fixture.account.tenant.id,
                       user_id: fixture.account.user.id,
                       pending_deletion_user_ids: [],
                       timestamp: fixture.timestamp
                     })

            send(parent, {:erasure_effect, receipt})
            if @rollback, do: Repo.rollback(:fixture_abort_after_erasure), else: receipt
          end)
        end)

      assert_receive {:eraser_backend, eraser_backend}, 5_000
      {query, blockers} = wait_for_lock(eraser_backend)
      assert String.contains?(query, ~s(UPDATE "sessions"))
      assert reader_backend in blockers

      unboxed(fn ->
        current = Repo.get!(User, fixture.account.user.id)
        assert current.email == fixture.account.user.email
        assert current.external_subject == fixture.account.user.external_subject
        assert current.status == :active
      end)

      send(reader_pid, {:release_barrier, release})
      assert {:ok, %{read_at: %DateTime{}}} = Task.await(reader, 10_000)
      erasure_result = Task.await(eraser, 10_000)
      assert_receive {:erasure_effect, receipt}, 5_000
      assert receipt.user_id == fixture.account.user.id
      assert receipt.revoked_session_ids == [fixture.account.session.id]

      if @rollback,
        do: assert(erasure_result == {:error, :fixture_abort_after_erasure}),
        else: assert(erasure_result == {:ok, receipt})

      unboxed(fn ->
        assert Repo.get_by!(VoicemailRead,
                 voicemail_id: fixture.voicemail.id,
                 user_id: fixture.account.user.id
               ).read_at

        user = Repo.get!(User, fixture.account.user.id)
        session = Repo.get!(Session, fixture.account.session.id)
        device = Repo.get!(Device, fixture.account.device.id)

        if @rollback do
          assert user.email == fixture.account.user.email
          assert user.external_subject == fixture.account.user.external_subject
          assert user.status == :active
          assert user.lock_version == fixture.account.user.lock_version
          refute session.revoked_at
          refute device.revoked_at
        else
          assert user.email == "deleted-#{user.id}@invalid.example"
          assert user.external_subject == "deleted-#{user.id}"
          assert user.status == :deleted
          assert user.lock_version == fixture.account.user.lock_version + 1
          assert session.revoked_at == fixture.timestamp
          assert device.revoked_at == fixture.timestamp
        end

        assert Repo.get!(User, fixture.remaining_owner.user.id).status == :active
      end)
    end
  end

  test "a real Settings-held phone Call finishes its actor FK before final identity key mutation" do
    fixture = fixture()
    parent = self()

    {subject, phone_call} =
      unboxed(fn ->
        subject = Fixtures.step_up(fixture.account)

        call =
          Repo.get!(Call, fixture.voicemail.call_id)
          |> Call.changeset(%{
            status: :answered,
            answered_at: DateTime.utc_now(),
            ended_at: nil,
            end_reason: nil,
            cleanup_completed_at: nil,
            answer_session_id: fixture.account.session.id,
            answer_device_id: fixture.account.device.id,
            dispatch_status: :started
          })
          |> Repo.update!()

        {subject, call}
      end)

    settings =
      actor(
        parent,
        :settings,
        fn ->
          Administration.update_tenant_settings(
            %{version: 1, name: "Governed call/FK overlap fixture", allow_audio_calls: false},
            subject
          )
        end,
        barrier: fn query ->
          String.contains?(query, ~s(FROM "telephony_calls")) and
            String.contains?(query, "FOR UPDATE")
        end
      )

    assert_receive {:settings_backend, settings_backend}, 5_000
    assert_receive {:settings_barrier, settings_pid, release}, 5_000

    eraser =
      actor(parent, :eraser, fn ->
        Repo.transaction(fn ->
          command = %GovernanceErasureCommand{
            tenant_id: fixture.account.tenant.id,
            user_id: fixture.account.user.id,
            pending_deletion_user_ids: [],
            timestamp: fixture.timestamp
          }

          assert {:ok, receipt} = Accounts.drain_user_for_governance(command)
          assert {:ok, _finalized} = Accounts.finalize_user_for_governance_erasure(command)
          receipt
        end)
      end)

    assert_receive {:eraser_backend, eraser_backend}, 5_000
    {query, blockers} = wait_for_lock(eraser_backend)
    assert String.contains?(query, ~s(FROM "telephony_calls"))
    assert settings_backend in blockers

    unboxed(fn ->
      assert Repo.get!(User, fixture.account.user.id).external_subject ==
               fixture.account.user.external_subject
    end)

    # Settings still must insert its real Audit.actor User FK after this
    # retained Call. A strong anonymization lock here would form the cycle.
    send(settings_pid, {:release_barrier, release})
    assert {:ok, _settings} = Task.await(settings, 10_000)
    assert {:ok, receipt} = Task.await(eraser, 10_000)
    assert receipt.revoked_session_ids == [fixture.account.session.id]

    unboxed(fn ->
      assert Repo.get!(Call, phone_call.id).status == :ended
      assert Repo.get!(User, fixture.account.user.id).status == :deleted
    end)
  end

  defp fixture do
    account = unboxed(fn -> Fixtures.account_fixture() end)
    register_cleanup(account)

    fixture =
      unboxed(fn ->
        remaining_owner = Fixtures.user_fixture(account, %{role: :owner})

        %{
          account: account,
          remaining_owner: remaining_owner,
          voicemail: available_voicemail(account),
          timestamp: DateTime.utc_now()
        }
      end)

    fixture
  end

  defp register_cleanup(account) do
    on_exit(fn ->
      unboxed(fn ->
        call_ids =
          Repo.all(
            from(call in Call,
              where: call.tenant_id == ^account.tenant.id,
              select: call.id
            )
          )

        event_ids =
          Repo.all(
            from(event in OutboxEvent,
              where: event.tenant_id == ^account.tenant.id,
              select: event.id
            )
          )

        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("?->>'tenant_id' = ?", job.args, ^account.tenant.id)
          )
        )

        Repo.delete_all(
          from(job in Oban.Job, where: fragment("?->>'call_id'", job.args) in ^call_ids)
        )

        Repo.delete_all(
          from(job in Oban.Job, where: fragment("?->>'event_id'", job.args) in ^event_ids)
        )

        # These synthetic voicemail tables intentionally use restrictive FKs.
        # Remove only this fixture tenant's owned children before Tenant cascade.
        Repo.delete_all(from(read in VoicemailRead, where: read.tenant_id == ^account.tenant.id))

        Repo.delete_all(
          from(message in Voicemail, where: message.tenant_id == ^account.tenant.id)
        )

        Repo.delete_all(from(box in Mailbox, where: box.tenant_id == ^account.tenant.id))
        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^account.tenant.id))
      end)
    end)

    :ok
  end

  # Canonical persisted, pinned synthetic metadata; read-state has no media or
  # provider effect. This test invokes the real protected mark-read operation.
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
        direction: :inbound,
        status: :ended,
        from_number: "+14155550200",
        to_number: number.phone_number,
        extension: number.extension,
        inbound_trunk_id: number.inbound_trunk_id,
        outbound_trunk_id: number.outbound_trunk_id,
        provider_room: "identity-fk-room-" <> suffix,
        provider_identity: "identity-fk-caller-" <> suffix,
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
      recording_name: "identity_fk_" <> suffix,
      notice_media: box.notice_media,
      status: :available,
      recording_deadline: DateTime.add(now, 60, :second),
      retention_expires_at: DateTime.add(now, 86400, :second),
      available_at: now,
      provider_deleted_at: now,
      duration_seconds: 2,
      byte_size: 32,
      object_key: "synthetic/identity-fk-" <> suffix,
      object_version_id: "exact-fixture-version",
      object_etag: "exact-fixture-etag",
      checksum_sha256: String.duplicate("a", 64),
      verified_checksum_sha256: String.duplicate("a", 64)
    })
    |> Repo.insert!()
  end

  defp actor(parent, label, operation, opts \\ []) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})
          if matcher = Keyword.get(opts, :barrier), do: attach_barrier(parent, label, matcher)
          operation.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
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
              12_000 -> raise "identity User-reference query barrier timed out"
            end
          end
        end,
        nil
      )
  end

  defp wait_for_lock(backend, attempts \\ 300)
  defp wait_for_lock(_backend, 0), do: flunk("identity did not reach an actual Session lock wait")

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
