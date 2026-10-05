defmodule CommsCore.AudioCalls.Artifacts.DerivedAuthority do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Accounts.GuestIdentityParentsLockQuery
  alias CommsCore.AudioCalls.AudioCallParticipant
  alias CommsCore.AudioCalls.Artifacts.Consent

  # Caller already holds the Governance barrier. Retain quota/Tenant and ALL
  # sorted User parents before any Device/Session/conversation/call/artifact.
  # Rejoin never substitutes a new session for an original capture admission.
  def lock!(source, requester, deadline) do
    case lock(source, requester, deadline) do
      {:ok, authority} -> authority
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def lock(source, requester, deadline) do
    try do
      {:ok, retain!(source, requester, deadline)}
    catch
      :throw, :derived_authority_denied -> {:error, :forbidden}
    end
  end

  defp retain!(source, requester, deadline) do
    consents =
      Repo.all(
        from(c in Consent,
          where: c.tenant_id == ^source.tenant_id and c.artifact_id == ^source.id
        )
      )

    if consents == [], do: throw(:derived_authority_denied)
    users = [requester.user_id | Enum.map(consents, & &1.user_id)] |> Enum.uniq() |> Enum.sort()

    query = %GuestIdentityParentsLockQuery{
      tenant_id: source.tenant_id,
      user_ids: users,
      deadline: deadline,
      require_active_tenant: true
    }

    case Accounts.lock_guest_identity_parents(query) do
      {:ok, _} -> :ok
      _ -> throw(:derived_authority_denied)
    end

    participants =
      Repo.all(
        from(p in AudioCallParticipant,
          where:
            p.tenant_id == ^source.tenant_id and
              p.audio_call_id == ^source.call_id and
              p.id in ^Enum.map(consents, & &1.participant_id)
        )
      )

    subjects =
      Enum.map(consents, fn consent ->
        p =
          Enum.find(participants, &(&1.id == consent.participant_id)) ||
            throw(:derived_authority_denied)

        if p.user_id != consent.user_id or p.session_id != consent.session_id or
             (p.status != :admitted and p.revocation_reason not in ["call_ended", "call_expired"]),
           do: throw(:derived_authority_denied)

        %{
          tenant_id: source.tenant_id,
          user_id: p.user_id,
          device_id: p.device_id,
          session_id: p.session_id
        }
      end)

    [requester | subjects]
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.user_id, &1.device_id, &1.session_id})
    |> Enum.each(fn subject ->
      case Accounts.lock_content_write_grant(subject, deadline) do
        {:ok, _} -> :ok
        _ -> throw(:derived_authority_denied)
      end
    end)

    {consents, subjects}
  end

  def current?(subjects, conversation_id) do
    Enum.all?(subjects, fn subject ->
      with {:ok, grant} <- Accounts.access_grant(subject),
           {:ok, _} <-
             Conversations.call_membership(grant.tenant_id, conversation_id, grant.user_id),
           do: true,
           else: (_ -> false)
    end)
  end
end
