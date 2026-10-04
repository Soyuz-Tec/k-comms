defmodule CommsCore.TelephonyConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo, Telephony}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Accounts.User
  alias CommsCore.Telephony.{Call, CredentialRequest}
  alias CommsIntegrations.Telephony.LiveKit
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  @moduletag :integration
  @moduletag :concurrency
  @moduletag :call

  setup do
    account = unboxed(fn -> Fixtures.account_fixture() end)
    previous = Application.get_env(:comms_core, :telephony_callback_adapter)
    Application.put_env(:comms_core, :telephony_callback_adapter, LiveKit)
    subject = unboxed(fn -> Fixtures.step_up(account) end)

    suffix =
      System.unique_integer([:positive])
      |> rem(100_000)
      |> Integer.to_string()
      |> String.pad_leading(5, "0")

    number = "+14155" <> suffix
    room = "kc_tel_inbound_" <> Ecto.UUID.generate()

    assert {:ok, _} =
             unboxed(fn ->
               Telephony.provision(
                 %{
                   phone_number: number,
                   extension: "101",
                   user_id: account.user.id,
                   inbound_trunk_id: "ST_concurrent_in",
                   outbound_trunk_id: "ST_concurrent_out",
                   reason: "Synthetic concurrency fixture"
                 },
                 subject
               )
             end)

    on_exit(fn ->
      unboxed(fn ->
        call_ids =
          Repo.all(from(c in Call, where: c.tenant_id == ^account.tenant.id, select: c.id))

        Repo.delete_all(
          from(j in Oban.Job,
            where:
              fragment("?->>'call_id'", j.args) in ^call_ids or
                fragment("?->>'tenant_id' = ?", j.args, ^account.tenant.id)
          )
        )

        Repo.delete_all(from(t in Tenant, where: t.id == ^account.tenant.id))
      end)

      if previous,
        do: Application.put_env(:comms_core, :telephony_callback_adapter, previous),
        else: Application.delete_env(:comms_core, :telephony_callback_adapter)
    end)

    %{account: account, subject: subject, number: number, room: room}
  end

  test "two real database connections cannot both claim incoming media", context do
    %{account: account, subject: subject, number: number, room: room} = context

    assert {:ok, call, :applied} =
             unboxed(fn ->
               Telephony.callback(
                 %{
                   event_id: "inbound_" <> room,
                   event_type: "participant_joined",
                   room: room,
                   participant_identity: "sip_" <> room,
                   participant_kind: :sip,
                   trunk_id: "ST_concurrent_in",
                   from_number: "+14155550200",
                   to_number: number
                 },
                 LiveKit
               )
             end)

    other_subject = unboxed(fn -> second_device(account) end)
    parent = self()

    first =
      Task.async(fn ->
        unboxed(fn ->
          Telephony.answer(call.id, subject, fn %CredentialRequest{} ->
            send(parent, {:answer_reserved, self()})

            receive do
              :continue -> {:ok, %{token: "first"}}
            after
              5_000 -> raise "answer barrier timeout"
            end
          end)
        end)
      end)

    assert_receive {:answer_reserved, first_pid}, 5_000

    second =
      Task.async(fn ->
        unboxed(fn ->
          Telephony.answer(call.id, other_subject, fn _ -> {:ok, %{token: "second"}} end)
        end)
      end)

    assert Task.yield(second, 100) == nil
    send(first_pid, :continue)
    assert {:ok, _, %{token: "first"}} = Task.await(first, 5_000)
    assert {:error, :answered_elsewhere} = Task.await(second, 5_000)
    assert unboxed(fn -> Repo.get!(Call, call.id).answer_session_id end) == account.session.id
  end

  test "signed app callback and actual session revocation serialize without deadlock or resurrection",
       context do
    %{account: account, subject: subject} = context

    assert {:ok, call, :created} =
             unboxed(fn ->
               Telephony.start_outbound(
                 %{destination: "+14155550200", idempotency_key: "concurrent_dispatch"},
                 subject
               )
             end)

    stored = unboxed(fn -> Repo.get!(Call, call.id) end)

    event = %{
      event_id: "callback_" <> call.id,
      event_type: "participant_joined",
      room: stored.provider_room,
      participant_identity: stored.app_identity,
      participant_kind: :standard,
      participant_sid: "PA_callback_" <> call.id,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    handler = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      handler,
      [:comms_core, :repo, :query],
      fn _, _, metadata, _ ->
        if Process.get(:phone_actor) == :callback and
             String.contains?(metadata.query, "FROM \"sessions\"") and
             String.contains?(metadata.query, "FOR SHARE") do
          send(parent, {:session_verified, self()})

          receive do
            :continue -> :ok
          after
            5_000 -> raise "identity barrier timeout"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    callback =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:phone_actor, :callback)
          Telephony.callback(event, LiveKit)
        end)
      end)

    assert_receive {:session_verified, callback_pid}, 5_000

    revoker =
      Task.async(fn ->
        unboxed(fn -> Accounts.revoke_own_session_command(account.session.id, subject) end)
      end)

    assert Task.yield(revoker, 100) == nil
    send(callback_pid, :continue)
    assert {:ok, _, :applied} = Task.await(callback, 5_000)
    assert :ok = Task.await(revoker, 5_000)
    assert unboxed(fn -> Repo.get!(Call, call.id).status end) == :ended

    assert {:ok, result, :ignored} =
             unboxed(fn ->
               Telephony.callback(%{event | event_id: "after_revocation"}, LiveKit)
             end)

    assert result.status == :ended
  end

  test "provisioning locks a lower-id assignee before the administrator like identity lifecycle",
       context do
    %{account: account, subject: subject, number: number} = context

    member =
      unboxed(fn ->
        suffix = System.unique_integer([:positive]) |> Integer.to_string()
        id = "00000000-0000-4000-8000-" <> String.pad_leading(suffix, 12, "0")

        %User{id: id}
        |> User.changeset(%{
          tenant_id: account.tenant.id,
          external_subject: "local:sorted-#{suffix}@example.test",
          display_name: "Sorted member",
          email: "sorted-#{suffix}@example.test",
          role: :member,
          status: :active
        })
        |> Repo.insert!()
      end)

    assert member.id < account.user.id
    parent = self()

    mutator =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.one!(from(u in User, where: u.id == ^member.id, lock: "FOR UPDATE"))
            send(parent, {:lower_user_locked, self()})

            receive do
              :continue -> :ok
            after
              5_000 -> raise "sorted user barrier timeout"
            end

            Accounts.change_user_with_effects_view(
              member.id,
              %{version: 1, role: :moderator, reason: "Concurrent role qualification"},
              subject
            )
          end)
        end)
      end)

    assert_receive {:lower_user_locked, mutator_pid}, 5_000

    provisioner =
      Task.async(fn ->
        unboxed(fn ->
          Telephony.provision(
            %{
              phone_number: number,
              extension: "101",
              user_id: member.id,
              inbound_trunk_id: "ST_concurrent_in",
              outbound_trunk_id: "ST_concurrent_out",
              reason: "Concurrent assignment qualification"
            },
            subject
          )
        end)
      end)

    assert Task.yield(provisioner, 100) == nil
    send(mutator_pid, :continue)
    assert {:ok, {:ok, _}} = Task.await(mutator, 5_000)
    assert {:ok, configured} = Task.await(provisioner, 5_000)
    assert configured.number.user_id == member.id
  end

  defp second_device(account) do
    suffix = account.tenant.slug |> String.split("-") |> List.last()

    {:ok, authentication} =
      Accounts.authenticate_view(
        account.tenant.slug,
        account.user.email,
        "correct-horse-battery-#{suffix}",
        %{name: "Concurrent device", platform: "test"}
      )

    {:ok, context} = Accounts.access_context(authentication.session_id)
    context.subject
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
