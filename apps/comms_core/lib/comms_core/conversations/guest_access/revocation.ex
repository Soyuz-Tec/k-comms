defmodule CommsCore.Conversations.GuestAccess.Revocation do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Conversations.Membership

  def lock_admission_membership!(admission) do
    Repo.one(
      from(membership in Membership,
        where:
          membership.id == ^admission.membership_id and
            membership.tenant_id == ^admission.tenant_id and
            membership.conversation_id == ^admission.conversation_id and
            membership.user_id == ^admission.guest_user_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:forbidden)
  end

  def revoke_admission!(admission, timestamp, reason, call_access_revoker) do
    membership = lock_admission_membership!(admission)

    revoke_locked_admission!(
      admission,
      membership,
      timestamp,
      reason,
      call_access_revoker
    )
  end

  def revoke_locked_admission!(
        admission,
        membership,
        timestamp,
        reason,
        call_access_revoker
      ) do
    if is_nil(membership.left_at) do
      membership
      |> Membership.changeset(%{left_at: timestamp})
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()
    end

    revoke_guest_session!(admission.session_id, reason)

    call_access_revoker.(
      admission.tenant_id,
      admission.conversation_id,
      admission.guest_user_id,
      reason
    )
    |> transaction_step_ok!()

    admission
    |> CommsCore.Conversations.GuestAdmission.changeset(%{revoked_at: timestamp})
    |> update_or_rollback()

    admission.session_id
  end

  defp revoke_guest_session!(session_id, reason) do
    case Accounts.revoke_guest_session(session_id, reason) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction_step_ok!(:ok), do: :ok
  defp transaction_step_ok!({:error, reason}), do: Repo.rollback(reason)

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
