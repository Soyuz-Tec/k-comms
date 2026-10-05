defmodule CommsCore.Accounts.IdentityUserReferenceLockOrderTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias CommsCore.{Accounts, PasswordRecovery, Repo, Telephony}
  alias CommsCore.Accounts.{Device, MfaFactor, PasswordRecoveryRequest, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Security.Password
  alias CommsCore.Telephony.{Call, Mailbox, Number, Voicemail, VoicemailRead}
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @password "identity-user-reference-fixture-password-1234"
  @new_password "identity-user-reference-replacement-password-9876"

  setup do
    previous = Application.fetch_env(:comms_core, :identity_secret_encryption_key)
    Application.put_env(:comms_core, :identity_secret_encryption_key, String.duplicate("i", 32))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:comms_core, :identity_secret_encryption_key, value)
        :error -> Application.delete_env(:comms_core, :identity_secret_encryption_key)
      end
    end)

    :ok
  end

  for operation <- [:mfa_enroll, :password_change, :password_reset] do
    @operation operation

    test "#{operation} lets a real Session-retaining voicemail read finish its User FK before credential effect" do
      fixture = fixture(@operation)
      parent = self()

      reader =
        actor(
          parent,
          :reader,
          fn ->
            Telephony.mark_voicemail_read(fixture.voicemail.id, fixture.reader_subject)
          end,
          barrier: fn query ->
            String.contains?(query, ~s(FROM "sessions")) and
              String.contains?(query, "FOR SHARE")
          end
        )

      assert_receive {:reader_backend, reader_backend}, 5_000
      assert_receive {:reader_barrier, reader_pid, release}, 5_000

      # The real voicemail command retains Session SHARE before inserting its
      # owned VoicemailRead row and checking the actor User FK. The identity
      # effect must permit that reference while waiting for this Session.
      identity = actor(parent, :identity, fn -> invoke(@operation, fixture) end)
      assert_receive {:identity_backend, identity_backend}, 5_000
      {query, blockers} = wait_for_lock(identity_backend)

      if @operation == :mfa_enroll,
        do: assert(String.contains?(query, ~s(FROM "sessions"))),
        else: assert(String.contains?(query, ~s(UPDATE "sessions")))

      assert reader_backend in blockers
      send(reader_pid, {:release_barrier, release})
      assert {:ok, %{read_at: %DateTime{}}} = Task.await(reader, 10_000)
      assert {:ok, result} = Task.await(identity, 10_000)

      unboxed(fn ->
        assert Repo.get_by!(VoicemailRead,
                 voicemail_id: fixture.voicemail.id,
                 user_id: fixture.account.user.id
               ).read_at

        case @operation do
          :mfa_enroll ->
            assert result.secret
            assert Repo.get_by!(MfaFactor, user_id: fixture.account.user.id)
            refute Repo.get!(Session, fixture.account.session.id).revoked_at

          :password_change ->
            assert fixture.reader_session.id in result.revoked_session_ids
            assert Repo.get!(Session, fixture.reader_session.id).revoked_at
            refute Repo.get!(Session, fixture.account.session.id).revoked_at

            assert Password.verify(
                     @new_password,
                     Repo.get!(User, fixture.account.user.id).password_hash
                   )

          :password_reset ->
            assert fixture.reader_session.id in result.revoked_session_ids
            assert Repo.get!(Session, fixture.reader_session.id).revoked_at
            assert Repo.get!(Session, fixture.account.session.id).revoked_at
            assert Repo.get!(PasswordRecoveryRequest, fixture.recovery_id).consumed_at

            assert Password.verify(
                     @new_password,
                     Repo.get!(User, fixture.account.user.id).password_hash
                   )

            assert {:error, :invalid_password_recovery_token} =
                     PasswordRecovery.reset(%{
                       token: fixture.recovery_token,
                       new_password: @password
                     })
        end
      end)
    end
  end

  defp fixture(operation) do
    account = unboxed(fn -> Fixtures.account_fixture(%{password: @password}) end)
    register_cleanup(account)

    fixture =
      unboxed(fn ->
        subject = Fixtures.subject(account)
        {:ok, _} = Accounts.step_up_view(%{current_password: @password}, subject)

        reader_session =
          if operation == :mfa_enroll do
            Repo.get!(Session, account.session.id)
          else
            {:ok, login} =
              Accounts.authenticate_view(account.tenant.slug, account.user.email, @password, %{})

            Repo.get!(Session, login.session_id)
          end

        reader_device =
          Repo.get_by!(Device,
            id: reader_session.device_id,
            tenant_id: account.tenant.id,
            user_id: account.user.id
          )

        reader_subject =
          Fixtures.subject(%{account | session: reader_session, device: reader_device})

        voicemail = available_voicemail(account)

        fixture = %{
          account: account,
          subject: subject,
          reader_subject: reader_subject,
          reader_session: reader_session,
          voicemail: voicemail
        }

        if operation == :password_reset do
          :ok =
            PasswordRecovery.request(%{
              tenant_slug: account.tenant.slug,
              email: account.user.email
            })

          recovery = Repo.get_by!(PasswordRecoveryRequest, user_id: account.user.id)

          {:ok, delivery} =
            PasswordRecovery.materialize_notification(%{
              tenant_id: account.tenant.id,
              user_id: account.user.id,
              recovery_request_id: recovery.id
            })

          token =
            delivery.payload["action_url"]
            |> URI.parse()
            |> Map.fetch!(:fragment)
            |> URI.decode_query()
            |> Map.fetch!("token")

          Map.merge(fixture, %{recovery_id: recovery.id, recovery_token: token})
        else
          fixture
        end
      end)

    fixture
  end

  defp register_cleanup(account) do
    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("?->>'tenant_id' = ?", job.args, ^account.tenant.id)
          )
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

  defp invoke(:mfa_enroll, fixture), do: Accounts.enroll_mfa(fixture.subject)

  defp invoke(:password_change, fixture),
    do:
      Accounts.change_password_command(
        %{
          current_password: @password,
          new_password: @new_password
        },
        fixture.subject
      )

  defp invoke(:password_reset, fixture),
    do:
      PasswordRecovery.reset(%{
        token: fixture.recovery_token,
        new_password: @new_password
      })

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
