defmodule CommsCore.WhiteboardCapacityConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Repo, Whiteboards}
  alias CommsCore.Administration.Tenant
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :concurrency

  test "two authors on separate connections cannot both consume the final scene slot" do
    {account, other_subject} =
      unboxed(fn ->
        account = Fixtures.account_fixture()
        member = Fixtures.user_fixture(account).user
        suffix = member.email |> String.split("@") |> hd() |> String.replace_prefix("member-", "")

        {:ok, signed_in} =
          Accounts.authenticate_view(
            account.tenant.slug,
            member.email,
            "correct-horse-battery-#{suffix}",
            %{name: "Capacity test", platform: "test"}
          )

        {:ok, access} = Accounts.access_context(signed_in.session_id)

        {:ok, _} =
          Conversations.add_member(
            account.conversation.id,
            member.id,
            :member,
            Fixtures.subject(account)
          )

        for batch <- 0..24 do
          last = min((batch + 1) * 200, 4_999)
          elements = for n <- (batch * 200 + 1)..last, do: element(n)

          assert {:ok, _, :created} =
                   append(account, Fixtures.subject(account), "seed-batch-#{batch}", elements)
        end

        {account, access.subject}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("?->>'tenant_id' = ?", job.args, ^account.tenant.id)
          )
        )

        Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^account.tenant.id))
      end)
    end)

    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:comms_core, :repo, :query],
      fn _, _, metadata, _ ->
        if Process.get(:capacity_writer) == :first and
             String.contains?(metadata.query, ~s(FROM "whiteboards")) and
             String.contains?(metadata.query, "FOR UPDATE") do
          send(parent, {:board_locked, self()})

          receive do
            :continue -> :ok
          after
            5_000 -> raise "capacity barrier timeout"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    first =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:capacity_writer, :first)
          append(account, Fixtures.subject(account), "race-first", [element(5000)])
        end)
      end)

    assert_receive {:board_locked, pid}, 5_000

    second =
      Task.async(fn ->
        unboxed(fn -> append(account, other_subject, "race-second", [element(5001)]) end)
      end)

    assert Task.yield(second, 100) == nil
    send(pid, :continue)
    assert {:ok, _, :created} = Task.await(first, 5_000)
    assert {:error, :whiteboard_capacity_exceeded} = Task.await(second, 5_000)
  end

  defp append(account, subject, id, elements),
    do:
      Whiteboards.append_operation(
        account.conversation.id,
        %{client_operation_id: id, kind: "scene.update", payload: %{"elements" => elements}},
        subject
      )

  defp element(n),
    do: %{"id" => "element-#{n}", "type" => "rectangle", "version" => 1, "versionNonce" => 1}

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
