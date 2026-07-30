defmodule CommsCore.Conversations.GuestAccess.AdmissionLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{AdmissionQuotas, Audit, Repo}

  alias CommsCore.Conversations.{
    Conversation,
    EphemeralRooms,
    GuestAdmission,
    GuestLink
  }

  alias CommsCore.Conversations.GuestAccess.Revocation

  def logout_session(guest_subject, call_access_revoker)
      when is_map(guest_subject) and is_function(call_access_revoker, 4) do
    admission_id =
      value(guest_subject, :guest_admission_id) || value(guest_subject, :admission_id)

    conversation_id =
      value(guest_subject, :guest_conversation_id) ||
        value(guest_subject, :conversation_id)

    with {:ok, admission_id} <- Ecto.UUID.cast(admission_id),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         %GuestAdmission{} = snapshot <-
           admission_snapshot(admission_id, conversation_id, guest_subject) do
      case Repo.transaction(fn ->
             _policy = admission_policy!(snapshot.tenant_id)
             _conversation = lock_expiry_conversation!(snapshot)
             link = lock_expiry_link!(snapshot)
             ephemeral_room = EphemeralRooms.lock_conversion_room(link)
             admission = lock_expiry_admission!(snapshot)
             membership = Revocation.lock_admission_membership!(admission)
             timestamp = now()

             unless admission.revoked_at || admission.converted_at do
               Revocation.revoke_locked_admission!(
                 admission,
                 membership,
                 timestamp,
                 "guest_logout",
                 call_access_revoker
               )

               EphemeralRooms.close_logged_out_presence(
                 ephemeral_room,
                 admission.guest_user_id,
                 admission.session_id,
                 timestamp
               )

               audit!(
                 admission.tenant_id,
                 admission.guest_user_id,
                 "conversation.guest.logged_out",
                 "conversation_guest_admission",
                 admission.id,
                 %{
                   conversation_id: admission.conversation_id,
                   guest_link_id: admission.guest_link_id
                 },
                 value(guest_subject, :request_id)
               )
             end

             :ok
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  def logout_session(_guest_subject, _call_access_revoker), do: {:error, :forbidden}

  def expire_admission(admission_id, call_access_revoker)
      when is_binary(admission_id) and is_function(call_access_revoker, 4) do
    with {:ok, admission_id} <- Ecto.UUID.cast(admission_id),
         %GuestAdmission{} = snapshot <- Repo.get(GuestAdmission, admission_id) do
      Repo.transaction(fn ->
        _policy = admission_policy!(snapshot.tenant_id)
        _conversation = lock_expiry_conversation!(snapshot)
        _link = lock_expiry_link!(snapshot)
        admission = lock_expiry_admission!(snapshot)

        cond do
          admission.revoked_at || admission.converted_at ->
            :already_terminal

          true ->
            membership = Revocation.lock_admission_membership!(admission)
            timestamp = now()

            if DateTime.compare(admission.expires_at, timestamp) == :gt do
              {:not_due, max(DateTime.diff(admission.expires_at, timestamp, :second), 1)}
            else
              Revocation.revoke_locked_admission!(
                admission,
                membership,
                timestamp,
                "guest_admission_expired",
                call_access_revoker
              )

              audit!(
                admission.tenant_id,
                nil,
                "conversation.guest.expired",
                "conversation_guest_admission",
                admission.id,
                %{
                  conversation_id: admission.conversation_id,
                  guest_link_id: admission.guest_link_id
                },
                "guest-admission-expiry:#{admission.id}"
              )

              :expired
            end
        end
      end)
      |> transaction_result()
    else
      _ -> {:error, :guest_admission_not_found}
    end
  end

  def expire_admission(_admission_id, _call_access_revoker),
    do: {:error, :guest_admission_not_found}

  defp admission_snapshot(admission_id, conversation_id, guest_subject) do
    Repo.one(
      from(admission in GuestAdmission,
        where:
          admission.id == ^admission_id and
            admission.tenant_id == ^value(guest_subject, :tenant_id) and
            admission.conversation_id == ^conversation_id and
            admission.guest_user_id == ^value(guest_subject, :user_id) and
            admission.session_id == ^value(guest_subject, :session_id)
      )
    )
  end

  defp lock_expiry_conversation!(snapshot) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.id == ^snapshot.conversation_id and
            conversation.tenant_id == ^snapshot.tenant_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:guest_admission_not_found)
  end

  defp lock_expiry_link!(snapshot) do
    Repo.one(
      from(link in GuestLink,
        where:
          link.id == ^snapshot.guest_link_id and link.tenant_id == ^snapshot.tenant_id and
            link.conversation_id == ^snapshot.conversation_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:guest_admission_not_found)
  end

  defp lock_expiry_admission!(snapshot) do
    Repo.one(
      from(admission in GuestAdmission,
        where:
          admission.id == ^snapshot.id and admission.tenant_id == ^snapshot.tenant_id and
            admission.conversation_id == ^snapshot.conversation_id and
            admission.guest_link_id == ^snapshot.guest_link_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:guest_admission_not_found)
  end

  defp audit!(tenant_id, actor_user_id, action, resource_type, resource_id, metadata, request_id) do
    case Audit.record(%{
           tenant_id: tenant_id,
           actor_user_id: actor_user_id,
           action: action,
           resource_type: resource_type,
           resource_id: resource_id,
           metadata: metadata,
           request_id: request_id
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp admission_policy!(tenant_id) do
    case AdmissionQuotas.locked_policy(tenant_id) do
      {:ok, policy} -> policy
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
