defmodule CommsCore.WhiteboardsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CommsCore.{Repo, Whiteboards}
  alias CommsCore.Administration.Tenant
  alias CommsTestSupport.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :whiteboard
  @moduletag :integration
  @moduletag :concurrency

  test "serializes concurrent collaborators without sequence loss" do
    account =
      Sandbox.unboxed_run(Repo, fn ->
        Fixtures.account_fixture(%{
          tenant_slug: "whiteboard-concurrency-" <> String.replace(Ecto.UUID.generate(), "-", "")
        })
      end)

    subject = Fixtures.subject(account)
    parent = self()

    # Only this newly generated disposable tenant and its own bootstrap jobs
    # are removed. Preexisting retained records and migration evidence remain.
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          tenant_id = account.tenant.id

          event_ids =
            Repo.all(
              from(event in CommsCore.Events.OutboxEvent,
                where: event.tenant_id == ^tenant_id,
                select: event.id
              )
            )

          Repo.delete_all(
            from(job in Oban.Job,
              where:
                fragment("?->>'tenant_id' = ?", job.args, ^tenant_id) or
                  fragment("?->>'event_id' = ANY(?::text[])", job.args, ^event_ids)
            )
          )

          Repo.delete_all(from(tenant in Tenant, where: tenant.id == ^tenant_id))
        end)
      end)
    end)

    # Each actor owns a distinct PostgreSQL connection; a shared SQL Sandbox
    # transaction cannot exercise the production cross-transaction row locks.
    stream =
      Task.async(fn ->
        1..12
        |> Task.async_stream(
          fn number ->
            Sandbox.unboxed_run(Repo, fn ->
              [[backend]] = Repo.query!("SELECT pg_backend_pid()", []).rows

              if number <= 6 do
                send(parent, {:whiteboard_actor_ready, number, self(), backend})

                receive do
                  :append -> :ok
                after
                  10_000 -> raise "whiteboard concurrent start barrier expired"
                end
              end

              Whiteboards.append_operation(
                account.conversation.id,
                %{
                  client_operation_id: "concurrent-operation-#{number}",
                  kind: "scene.update",
                  payload: %{"elements" => [element("element-#{number}", 1, number)]}
                },
                subject
              )
            end)
          end,
          max_concurrency: 6,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end)

    on_exit(fn -> if Process.alive?(stream.pid), do: Process.exit(stream.pid, :kill) end)

    actors =
      for _ <- 1..6 do
        assert_receive {:whiteboard_actor_ready, number, actor, backend}, 10_000
        {number, actor, backend}
      end

    assert actors |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.to_list(1..6)
    assert actors |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length() == 6
    Enum.each(actors, fn {_number, actor, _backend} -> send(actor, :append) end)
    results = Task.await(stream, 10_000)

    assert Enum.all?(results, &match?({:ok, _, :created}, &1))

    assert results |> Enum.map(fn {:ok, operation, _} -> operation.sequence end) |> Enum.sort() ==
             Enum.to_list(1..12)

    assert Sandbox.unboxed_run(Repo, fn ->
             Repo.all(
               from(operation in CommsCore.Whiteboards.Operation,
                 where:
                   operation.tenant_id == ^account.tenant.id and
                     operation.conversation_id == ^account.conversation.id,
                 order_by: operation.sequence,
                 select: operation.sequence
               )
             )
           end) == Enum.to_list(1..12)
  end

  defp element(id, version, nonce) do
    %{
      "id" => id,
      "type" => "rectangle",
      "version" => version,
      "versionNonce" => nonce,
      "link" => nil,
      "customData" => nil,
      "x" => 10,
      "y" => 20,
      "width" => 100,
      "height" => 80,
      "isDeleted" => false
    }
  end
end
