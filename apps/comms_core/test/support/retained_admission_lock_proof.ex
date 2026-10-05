defmodule CommsCore.RetainedAdmissionLockProof do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{AdmissionQuotas, Administration, Repo}
  alias CommsCore.Accounts.User
  alias Ecto.Adapters.SQL.Sandbox

  # Observe the actual retained 64-bit lock, including its exact namespace,
  # tenant, waiting PID and granted holder. Generic advisory query text cannot
  # distinguish this early identity-admission fence from a late author fence.
  def waiting_on_admission?(waiter, holder, tenant) do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[waiting?]]} =
        Repo.query!(
          """
          WITH expected AS (SELECT hashtextextended($3::text, 0) AS value)
          SELECT EXISTS (
            SELECT 1 FROM pg_locks AS waiting
            JOIN pg_locks AS retained ON
              retained.locktype = waiting.locktype AND
              retained.database = waiting.database AND
              retained.classid = waiting.classid AND
              retained.objid = waiting.objid AND
              retained.objsubid = waiting.objsubid
            CROSS JOIN expected
            WHERE waiting.pid = $1 AND NOT waiting.granted AND
              waiting.locktype = 'advisory' AND waiting.objsubid = 1 AND
              waiting.classid = ((expected.value >> 32) & 4294967295)::oid AND
              waiting.objid = (expected.value & 4294967295)::oid AND
              retained.pid = $2 AND retained.granted AND
              $2 = ANY(pg_blocking_pids($1))
          )
          """,
          [waiter, holder, "k-comms:tenant-admission:v1:" <> tenant]
        )

      waiting?
    end)
  end

  def retain_canonical_identity_prefix!(tenant) do
    :ok = AdmissionQuotas.lock_tenant(tenant)
    {:ok, _} = Administration.lock_call_policy(tenant)

    Repo.all(
      from(user in User,
        where: user.tenant_id == ^tenant,
        order_by: [asc: user.id],
        select: user.id,
        lock: "FOR NO KEY UPDATE"
      )
    )

    :ok
  end
end
