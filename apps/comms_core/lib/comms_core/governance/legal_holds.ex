defmodule CommsCore.Governance.LegalHolds do
  @moduledoc false

  import Ecto.Query
  import CommsCore.Governance.Support

  alias CommsCore.Governance.{
    Authorization,
    DeletionRequest,
    LegalHold,
    TenantLock
  }

  alias CommsCore.{Accounts, Conversations, Repo}

  def create_legal_hold(attrs, subject) when is_map(attrs) do
    tenant_id = value(subject, :tenant_id)
    idempotency_key = value(attrs, :idempotency_key)

    with :ok <- Authorization.authorize(subject),
         :ok <- validate_hold_target(attrs, tenant_id) do
      Repo.transaction(fn ->
        TenantLock.lock!(tenant_id)

        if Repo.exists?(
             from(r in DeletionRequest,
               where: r.tenant_id == ^tenant_id and r.status == :in_progress
             )
           ),
           do: Repo.rollback(:deletion_in_progress)

        case existing_idempotent(LegalHold, tenant_id, idempotency_key) do
          %LegalHold{} = hold ->
            %{hold: hold, replayed: true}

          nil ->
            id = Ecto.UUID.generate()

            hold =
              %LegalHold{id: id}
              |> LegalHold.changeset(%{
                tenant_id: tenant_id,
                created_by_user_id: value(subject, :user_id),
                subject_user_id: value(attrs, :subject_user_id),
                conversation_id: value(attrs, :conversation_id),
                name: value(attrs, :name),
                reason: value(attrs, :reason),
                scope_type: value(attrs, :scope_type),
                status: :active,
                starts_at: now(),
                idempotency_key: idempotency_key
              })
              |> insert_or_rollback()

            audit!(subject, "legal_hold.create", "legal_hold", hold.id, %{
              scope_type: hold.scope_type
            })

            %{hold: hold, replayed: false}
        end
      end)
      |> transaction_result()
    end
  end

  def list_legal_holds(params, subject) do
    with :ok <- Authorization.authorize(subject) do
      query =
        LegalHold
        |> where([h], h.tenant_id == ^value(subject, :tenant_id))
        |> maybe_equal(:status, enum(value(params, :status), [:active, :released]))
        |> maybe_equal(
          :scope_type,
          enum(value(params, :scope_type), [:tenant, :user, :conversation])
        )
        |> order_by([h], desc: h.inserted_at)
        |> limit(^parse_limit(value(params, :limit)))

      {:ok, Repo.all(query)}
    end
  end

  def release_legal_hold(id, attrs, subject) do
    with :ok <- Authorization.authorize(subject),
         {:ok, expected_version} <- expected_version(attrs),
         :ok <- require_reason(value(attrs, :release_reason)) do
      Repo.transaction(fn ->
        hold = lock_record!(LegalHold, id, subject)
        verify_version!(hold, expected_version)
        if hold.status != :active, do: Repo.rollback(:legal_hold_not_active)

        updated =
          hold
          |> LegalHold.changeset(%{status: :released, released_at: now()})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        audit!(subject, "legal_hold.release", "legal_hold", hold.id, %{
          version: updated.lock_version,
          reason: value(attrs, :release_reason)
        })

        updated
      end)
      |> transaction_result()
    end
  end

  defp validate_hold_target(attrs, tenant_id) do
    case enum(value(attrs, :scope_type), [:tenant, :user, :conversation]) do
      :tenant ->
        if is_nil(value(attrs, :subject_user_id)) and is_nil(value(attrs, :conversation_id)),
          do: :ok,
          else: {:error, :invalid_governance_target}

      :user ->
        tenant_id
        |> Accounts.validate_governance_user(value(attrs, :subject_user_id))
        |> governance_target_result()

      :conversation ->
        validate_conversation(tenant_id, value(attrs, :conversation_id))

      nil ->
        {:error, :invalid_governance_target}
    end
  end

  defp validate_conversation(_tenant_id, nil), do: :ok

  defp validate_conversation(tenant_id, id) do
    tenant_id
    |> Conversations.validate_reference(id)
    |> governance_target_result()
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
