defmodule CommsCore.Accounts.GuestContentIdentityLockOrderTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import CommsCore.EphemeralRoomFixtures

  alias CommsCore.{Conversations, Messaging, Repo, RuntimePorts, Whiteboards}
  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Conversations.{EphemeralRoom, GuestAdmission, Membership}
  alias CommsCore.Messaging.Message
  alias CommsCore.Whiteboards.Operation
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency
  @password "guest-content-lock-order-password-1234"

  setup do
    enabled = Application.get_env(:comms_core, :instant_rooms_enabled)
    slug = Application.get_env(:comms_core, :instant_room_tenant_slug)

    on_exit(fn ->
      restore_env(:instant_rooms_enabled, enabled)
      restore_env(:instant_room_tenant_slug, slug)
    end)

    :ok
  end

  test "live Guest content and converted conversation-only content keep their supported scope" do
    fixture = fixture()

    unboxed(fn ->
      assert {:ok, _, :created} = write(:message, fixture, fixture.subject, "guest-positive")
      assert {:ok, _, :created} = write(:board, fixture, fixture.subject, "guest-positive")

      # Even an active durable membership cannot broaden the restricted board
      # scope. The Guest HTTP router separately pins the admitted conversation.
      Repo.insert!(
        Membership.changeset(%Membership{}, %{
          tenant_id: fixture.account.tenant.id,
          conversation_id: fixture.account.conversation.id,
          user_id: fixture.subject.user_id,
          role: :member,
          joined_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })
      )

      durable = %{fixture | conversation_id: fixture.account.conversation.id}
      assert {:error, :forbidden} = write(:board, durable, fixture.subject, "durable-denied")
      foreign = %{fixture | conversation_id: Ecto.UUID.generate()}

      assert {:error, :conversation_not_found} =
               write(:message, foreign, fixture.subject, "foreign-denied")

      assert effect_count(:message, foreign, "foreign-denied") == 0
      assert {:error, :forbidden} = write(:board, foreign, fixture.subject, "foreign-denied")

      assert {:ok, converted} = lifecycle(:conversion, fixture)
      assert converted.authentication.user.id == fixture.subject.user_id
      assert converted.authentication.user.account_type == :human
      assert converted.authentication.user.access_scope == :conversation_only
      human = authenticated_subject(converted.authentication)
      assert {:ok, _, :created} = write(:message, fixture, human, "converted-positive")
      assert {:ok, _, :created} = write(:board, fixture, human, "converted-positive")

      assert {:error, :forbidden} =
               write(:message, fixture, fixture.subject, "old-session-denied")

      assert {:error, :forbidden} = write(:board, fixture, fixture.subject, "old-session-denied")
      assert {:error, :forbidden} = write(:board, durable, human, "converted-durable-denied")
    end)
  end

  for operation <- [:conversion, :logout, :admission_expiry], content <- [:message, :board] do
    @operation operation
    @content content

    test "#{operation} reaches Guest User before resources and a waiting #{content} creates no effect" do
      fixture = fixture()
      if @operation == :admission_expiry, do: expire_admission_timestamp(fixture)
      parent = self()
      holder = hold_user(parent, fixture.subject.user_id)
      assert_receive {:holder_backend, holder_backend}, 5_000
      assert_receive {:parent_retained, holder_pid}, 5_000

      lifecycle = actor(parent, :lifecycle, fn -> lifecycle(@operation, fixture) end)
      assert_receive {:lifecycle_backend, lifecycle_backend}, 5_000
      {query, blockers} = wait_for_lock(lifecycle_backend)
      assert String.contains?(query, ~s(FROM "users"))
      assert String.contains?(query, "FOR NO KEY UPDATE")
      assert holder_backend in blockers

      writer =
        actor(parent, :writer, fn -> write(@content, fixture, fixture.subject, "loser") end)

      assert_receive {:writer_backend, writer_backend}, 5_000
      {query, blockers} = wait_for_lock(writer_backend)
      assert String.contains?(query, "pg_advisory_xact_lock")
      assert lifecycle_backend in blockers

      send(holder_pid, :release_parent)
      assert {:ok, :released} = Task.await(holder, 10_000)
      assert_lifecycle_success(@operation, Task.await(lifecycle, 10_000))
      assert {:error, :forbidden} = Task.await(writer, 10_000)

      unboxed(fn ->
        assert effect_count(@content, fixture, "loser") == 0
        assert Repo.get!(Session, fixture.subject.session_id).revoked_at
        admission = Repo.get!(GuestAdmission, fixture.joined.admission.id)

        if @operation == :conversion,
          do: assert(admission.converted_at),
          else: assert(admission.revoked_at)
      end)
    end
  end

  for content <- [:message, :board] do
    @content content

    test "a #{content} retaining Guest Session SHARE commits once before overlapping logout" do
      fixture = fixture()
      parent = self()

      writer =
        actor(parent, :writer, fn -> write(@content, fixture, fixture.subject, "winner") end,
          barrier: fn query ->
            String.contains?(query, ~s(FROM "sessions")) and String.contains?(query, "FOR SHARE")
          end
        )

      assert_receive {:writer_backend, writer_backend}, 5_000
      assert_receive {:writer_barrier, writer_pid, release}, 5_000
      logout = actor(parent, :logout, fn -> lifecycle(:logout, fixture) end)
      assert_receive {:logout_backend, logout_backend}, 5_000
      {query, blockers} = wait_for_lock(logout_backend)
      assert String.contains?(query, "pg_advisory_xact_lock")
      assert writer_backend in blockers

      send(writer_pid, {:release_barrier, release})
      assert {:ok, _, :created} = Task.await(writer, 10_000)
      assert :ok = Task.await(logout, 10_000)

      unboxed(fn ->
        assert effect_count(@content, fixture, "winner") == 1
        assert Repo.get!(Session, fixture.subject.session_id).revoked_at
        assert {:error, :forbidden} = write(@content, fixture, fixture.subject, "after-logout")
        assert effect_count(@content, fixture, "after-logout") == 0
      end)
    end
  end

  test "room expiry fences every pending Guest before resources even after identity and tenant expiry" do
    fixture = fixture()

    deadline =
      unboxed(fn ->
        assert {:ok, _, :created} = write(:board, fixture, fixture.subject, "reclaimed")

        deadline =
          DateTime.utc_now() |> DateTime.add(500, :millisecond) |> DateTime.truncate(:microsecond)

        original_absolute = Repo.get!(Session, fixture.subject.session_id).absolute_expires_at
        assert DateTime.compare(deadline, original_absolute) == :lt

        Repo.update_all(from(user in User, where: user.id == ^fixture.subject.user_id),
          set: [guest_expires_at: deadline]
        )

        Repo.update_all(
          from(session in Session, where: session.id == ^fixture.subject.session_id),
          set: [expires_at: deadline]
        )

        assert Repo.get!(Session, fixture.subject.session_id).absolute_expires_at ==
                 original_absolute

        Repo.update_all(from(tenant in Tenant, where: tenant.id == ^fixture.account.tenant.id),
          set: [status: :suspended]
        )

        Repo.update_all(from(room in EphemeralRoom, where: room.id == ^fixture.created.room.id),
          set: [
            status: :idle,
            idle_since: DateTime.add(deadline, -120, :second),
            expires_at: deadline
          ]
        )

        deadline
      end)

    wait_for_expiry(deadline)

    parent = self()
    holder = hold_user(parent, fixture.subject.user_id)
    assert_receive {:holder_backend, holder_backend}, 5_000
    assert_receive {:parent_retained, holder_pid}, 5_000

    expiry =
      actor(parent, :expiry, fn ->
        generation = Repo.get!(EphemeralRoom, fixture.created.room.id).generation

        Conversations.expire_ephemeral_room(
          fixture.created.room.id,
          generation,
          RuntimePorts.job_worker!(:ephemeral_room_lifecycle)
        )
      end)

    assert_receive {:expiry_backend, expiry_backend}, 5_000
    {query, blockers} = wait_for_lock(expiry_backend)
    assert String.contains?(query, ~s(FROM "users"))
    assert String.contains?(query, "FOR NO KEY UPDATE")
    assert holder_backend in blockers
    send(holder_pid, :release_parent)
    assert {:ok, :released} = Task.await(holder, 10_000)
    assert {:ok, :expired} = Task.await(expiry, 10_000)

    unboxed(fn ->
      assert Repo.get!(EphemeralRoom, fixture.created.room.id).status == :expired
      assert Repo.get!(GuestAdmission, fixture.joined.admission.id).revoked_at
      assert Repo.get!(Session, fixture.subject.session_id).revoked_at
      assert effect_count(:board, fixture, "reclaimed") == 0
    end)
  end

  test "creation replay takes the quota prefix and all pending Guest parents before the room" do
    fixture = fixture()
    parent = self()
    holder = hold_user(parent, fixture.subject.user_id)
    assert_receive {:holder_backend, holder_backend}, 5_000
    assert_receive {:parent_retained, holder_pid}, 5_000

    replay =
      actor(parent, :replay, fn ->
        Conversations.create_ephemeral_room(fixture.create_attrs, :guest)
      end)

    assert_receive {:replay_backend, replay_backend}, 5_000
    {query, blockers} = wait_for_lock(replay_backend)
    assert String.contains?(query, ~s(FROM "users"))
    assert String.contains?(query, "FOR NO KEY UPDATE")
    assert holder_backend in blockers
    send(holder_pid, :release_parent)
    assert {:ok, :released} = Task.await(holder, 10_000)
    assert {:ok, replayed} = Task.await(replay, 10_000)
    assert replayed.replayed
    assert replayed.room.id == fixture.created.room.id
    assert replayed.join_token == fixture.created.join_token
    refute replayed.authentication.session_id == fixture.created.authentication.session_id

    unboxed(fn ->
      assert {:ok, _, :created} =
               write(:board, fixture, fixture.subject, "other-guest-still-live")
    end)
  end

  defp fixture do
    fixture =
      unboxed(fn ->
        account =
          Fixtures.account_fixture(%{tenant_slug: "guest-content-" <> Ecto.UUID.generate()})

        create_attrs = guest_create_attrs(account.tenant.id, secret())
        {:ok, created} = Conversations.create_ephemeral_room(create_attrs, :guest)

        {:ok, joined} =
          Conversations.join_ephemeral_room(
            created.join_token,
            guest_join_attrs(secret()),
            :guest
          )

        %{
          account: account,
          created: created,
          joined: joined,
          create_attrs: create_attrs,
          subject: guest_subject(joined),
          conversation_id: created.conversation.id
        }
      end)

    on_exit(fn ->
      unboxed(fn ->
        tenant_id = fixture.account.tenant.id

        room_ids =
          Repo.all(
            from(room in EphemeralRoom, where: room.tenant_id == ^tenant_id, select: room.id)
          )

        admission_ids =
          Repo.all(
            from(admission in GuestAdmission,
              where: admission.tenant_id == ^tenant_id,
              select: admission.id
            )
          )

        conversation_ids = [fixture.conversation_id, fixture.account.conversation.id]

        # Room workers carry room_id without tenant_id. Delete only this
        # fixture's complete worker scope before cascading its tenant rows.
        Repo.delete_all(
          from(job in Oban.Job,
            where:
              fragment("?->>'tenant_id'", job.args) == ^tenant_id or
                fragment("?->>'room_id'", job.args) in ^room_ids or
                fragment("?->>'admission_id'", job.args) in ^admission_ids or
                fragment("?->>'conversation_id'", job.args) in ^conversation_ids
          )
        )

        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^tenant_id))
      end)
    end)

    fixture
  end

  defp lifecycle(:conversion, fixture) do
    Conversations.convert_guest_account(
      %{
        email: "guest-lock-#{fixture.subject.user_id}@example.test",
        password: @password,
        display_name: "Converted guest",
        device: %{name: "Converted browser", platform: "test"}
      },
      fixture.subject
    )
  end

  defp lifecycle(:logout, fixture), do: Conversations.logout_guest_session(fixture.subject)

  defp lifecycle(:admission_expiry, fixture),
    do:
      Conversations.expire_guest_admission(
        fixture.joined.admission.id,
        RuntimePorts.job_worker!(:guest_admission_expiry)
      )

  defp assert_lifecycle_success(:conversion, result), do: assert(match?({:ok, _}, result))
  defp assert_lifecycle_success(:logout, result), do: assert(result == :ok)
  defp assert_lifecycle_success(:admission_expiry, result), do: assert(result == {:ok, :expired})

  defp expire_admission_timestamp(fixture) do
    deadline =
      unboxed(fn ->
        deadline =
          DateTime.utc_now() |> DateTime.add(500, :millisecond) |> DateTime.truncate(:microsecond)

        Repo.update_all(
          from(admission in GuestAdmission, where: admission.id == ^fixture.joined.admission.id),
          set: [expires_at: deadline]
        )

        deadline
      end)

    wait_for_expiry(deadline)
  end

  defp write(:message, fixture, subject, key),
    do:
      Messaging.accept_message_with_status(
        %{
          tenant_id: subject.tenant_id,
          conversation_id: fixture.conversation_id,
          sender_user_id: subject.user_id,
          sender_device_id: subject.device_id,
          client_message_id: "guest-lock-#{key}",
          body: "Guest overlap #{key}"
        },
        subject
      )

  defp write(:board, fixture, subject, key),
    do:
      Whiteboards.append_operation(
        fixture.conversation_id,
        %{
          client_operation_id: "guest-lock-#{key}",
          kind: "scene.update",
          payload: %{
            "elements" => [
              %{
                "id" => "guest-element-#{key}",
                "type" => "rectangle",
                "version" => 1,
                "versionNonce" => 1
              }
            ]
          }
        },
        subject
      )

  defp effect_count(:message, fixture, key),
    do:
      Repo.aggregate(
        from(message in Message,
          where:
            message.tenant_id == ^fixture.account.tenant.id and
              message.conversation_id == ^fixture.conversation_id and
              message.client_message_id == ^"guest-lock-#{key}"
        ),
        :count
      )

  defp effect_count(:board, fixture, key),
    do:
      Repo.aggregate(
        from(operation in Operation,
          where:
            operation.tenant_id == ^fixture.account.tenant.id and
              operation.conversation_id == ^fixture.conversation_id and
              operation.client_operation_id == ^"guest-lock-#{key}"
        ),
        :count
      )

  defp hold_user(parent, user_id),
    do:
      actor(parent, :holder, fn ->
        Repo.transaction(fn ->
          Repo.one!(from(user in User, where: user.id == ^user_id, lock: "FOR NO KEY UPDATE"))
          send(parent, {:parent_retained, self()})

          receive do
            :release_parent -> :released
          after
            12_000 -> raise "Guest User parent holder timed out"
          end
        end)
      end)

  defp actor(parent, label, operation, opts \\ []) do
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        unboxed(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {String.to_atom("#{label}_backend"), backend})

          if matcher = Keyword.get(opts, :barrier),
            do: attach_barrier(parent, label, matcher, handler)

          operation.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp attach_barrier(parent, label, matcher, handler) do
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
              12_000 -> raise "Guest content authority barrier timed out"
            end
          end
        end,
        nil
      )
  end

  defp wait_for_lock(backend, attempts \\ 300)

  defp wait_for_lock(_backend, 0),
    do: flunk("Guest actor did not reach an actual database lock wait")

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

  defp wait_for_expiry(deadline, attempts \\ 200)

  defp wait_for_expiry(_deadline, 0),
    do: flunk("the valid synthetic expiry did not pass on the actual clock")

  defp wait_for_expiry(deadline, attempts) do
    if DateTime.compare(DateTime.utc_now(), deadline) == :lt do
      Process.sleep(10)
      wait_for_expiry(deadline, attempts - 1)
    else
      :ok
    end
  end

  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
