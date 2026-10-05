defmodule CommsCore.Accounts.MatrixParticipants do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Repo, AdmissionQuotas, Administration}
  alias CommsCore.Accounts.{MatrixParticipantsLockQuery, MatrixBudget, User}

  @spec lock(MatrixParticipantsLockQuery.t(), map() | nil) ::
          {:ok,
           %{eligible_user_ids: [String.t()], grant: CommsCore.Accounts.AccessGrant.t() | nil}}
          | {:error, atom()}
  def lock(
        %MatrixParticipantsLockQuery{tenant_id: tenant, user_ids: ids, deadline: deadline},
        subject
      ) do
    if Repo.in_transaction?() and is_integer(deadline) and is_list(ids) and length(ids) in 1..100 and
         length(Enum.uniq(ids)) == length(ids) and match?({:ok, _}, Ecto.UUID.cast(tenant)) and
         Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      MatrixBudget.prepare!(deadline)
      AdmissionQuotas.lock_tenant(tenant)
      MatrixBudget.prepare!(deadline)

      case Administration.lock_call_policy(tenant) do
        {:ok, _} -> :ok
        _ -> Repo.rollback(:forbidden)
      end

      # The tenant capacity fence serializes creations; all parent Users are
      # acquired in UUID order before ANY Device, Session or room resource.
      users =
        Repo.all(
          from(u in User,
            where: u.tenant_id == ^tenant and u.id in ^ids,
            order_by: u.id,
            lock: "FOR NO KEY UPDATE"
          )
        )

      MatrixBudget.check!(deadline)

      eligible =
        for u <- users,
            u.status == :active and u.account_type == :human and u.access_scope == :workspace,
            do: u.id

      grant =
        if is_nil(subject) do
          nil
        else
          case CommsCore.Accounts.ContentWriteGrant.lock(subject, deadline) do
            {:ok, %{tenant_id: ^tenant, account_type: :human, access_scope: :workspace} = grant} ->
              if grant.user_id not in ids, do: Repo.rollback(:forbidden)
              grant

            _ ->
              Repo.rollback(:forbidden)
          end
        end

      {:ok, %{eligible_user_ids: eligible, grant: grant}}
    else
      {:error, :invalid_matrix_participants_lock_query}
    end
  end

  def lock(_, _), do: {:error, :invalid_matrix_participants_lock_query}
end
