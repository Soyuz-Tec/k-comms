defmodule CommsCore.Governance.CalendarProtection do
  @moduledoc false
  @behaviour CommsCore.AudioCalls.CalendarSync.ProtectionPort
  import Ecto.Query
  alias CommsCore.AudioCalls.CalendarSync.{ProtectionQuery, ProtectionReceipt}
  alias CommsCore.Governance.{DeletionRequest, LegalHold, TenantLock}
  alias CommsCore.Repo

  @impl true
  def protection(%ProtectionQuery{deadline_ms: deadline} = query) when is_integer(deadline) do
    with true <- Repo.in_transaction?(),
         {:ok, tenant} <- Ecto.UUID.cast(query.tenant_id),
         true <- is_list(query.author_user_ids) and length(query.author_user_ids) in 1..5000,
         true <- Enum.all?(query.author_user_ids, &match?({:ok, _}, Ecto.UUID.cast(&1))),
         true <-
           is_nil(query.conversation_id) or
             match?({:ok, _}, Ecto.UUID.cast(query.conversation_id)) do
      budget!(deadline)
      TenantLock.lock!(tenant)
      budget!(deadline)
      authors = query.author_user_ids
      held_scope = dynamic([h], h.scope_type == :tenant or h.subject_user_id in ^authors)
      capture_scope = dynamic([r], r.target_type == :user and r.subject_user_id in ^authors)

      {held_scope, capture_scope} =
        if query.conversation_id do
          conversation = query.conversation_id

          {dynamic([h], ^held_scope or h.conversation_id == ^conversation),
           dynamic(
             [r],
             ^capture_scope or
               (r.target_type == :conversation and r.conversation_id == ^conversation)
           )}
        else
          {held_scope, capture_scope}
        end

      held =
        Repo.exists?(
          from(h in LegalHold,
            where: h.tenant_id == ^tenant and h.status == :active,
            where: ^held_scope
          )
        )

      blocked =
        Repo.exists?(
          from(r in DeletionRequest,
            where: r.tenant_id == ^tenant and r.status in [:approved, :in_progress],
            where: ^capture_scope
          )
        )

      budget!(deadline)
      {:ok, %ProtectionReceipt{held?: held, capture_blocked?: blocked}}
    else
      _ -> {:error, :calendar_protection_unavailable}
    end
  end

  def protection(_), do: {:error, :calendar_protection_unavailable}

  defp budget!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:calendar_protection_unavailable)
    timeout = Integer.to_string(remaining) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout',$1,true), set_config('statement_timeout',$1,true)",
      [timeout]
    )

    if System.monotonic_time(:millisecond) >= deadline,
      do: Repo.rollback(:calendar_protection_unavailable)
  end
end
