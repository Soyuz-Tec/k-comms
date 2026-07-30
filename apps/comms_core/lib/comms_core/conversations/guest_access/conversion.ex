defmodule CommsCore.Conversations.GuestAccess.Conversion do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{
    Accounts,
    AdmissionQuotas,
    Audit,
    Repo
  }

  alias CommsCore.Conversations.{
    Conversation,
    EphemeralRooms,
    GuestAdmission,
    GuestLink,
    Projector
  }

  alias CommsCore.Conversations.GuestAccess.{Revocation, Token}

  def convert_account(attrs, guest_subject)
      when is_map(attrs) and is_map(guest_subject) do
    admission_id =
      value(guest_subject, :guest_admission_id) || value(guest_subject, :admission_id)

    conversation_id =
      value(guest_subject, :guest_conversation_id) ||
        value(guest_subject, :conversation_id)

    with {:ok, admission_id} <- cast_uuid(admission_id),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         %GuestAdmission{} = snapshot <-
           admission_snapshot(admission_id, conversation_id, guest_subject) do
      Repo.transaction(fn ->
        _policy = admission_policy!(snapshot.tenant_id)
        conversation = lock_conversion_conversation!(snapshot)
        link = lock_conversion_link!(snapshot)
        ephemeral_room = EphemeralRooms.lock_conversion_room(link)

        admission =
          Repo.one(
            from(admission in GuestAdmission,
              where:
                admission.id == ^admission_id and
                  admission.tenant_id == ^snapshot.tenant_id and
                  admission.conversation_id == ^snapshot.conversation_id and
                  admission.guest_link_id == ^snapshot.guest_link_id and
                  admission.guest_user_id == ^snapshot.guest_user_id and
                  admission.session_id == ^snapshot.session_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:forbidden)

        membership = Revocation.lock_admission_membership!(admission)
        timestamp = now()
        ensure_convertible!(conversation, link, admission, membership, timestamp)

        authentication =
          case convert_guest_identity(link, admission, attrs, guest_subject) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end

        admission
        |> GuestAdmission.changeset(%{converted_at: timestamp})
        |> update_or_rollback()

        ephemeral_owner_upgraded =
          EphemeralRooms.upgrade_converted_owner(
            ephemeral_room,
            authentication,
            timestamp,
            value(guest_subject, :request_id)
          )

        EphemeralRooms.handoff_converted_presence(
          ephemeral_room,
          admission.session_id,
          authentication,
          timestamp
        )

        audit!(
          admission.tenant_id,
          admission.guest_user_id,
          "conversation.guest.converted",
          "conversation_guest_admission",
          admission.id,
          %{conversation_id: admission.conversation_id, guest_link_id: admission.guest_link_id},
          value(guest_subject, :request_id)
        )

        %{
          authentication: authentication,
          conversation: Projector.conversation(conversation),
          ephemeral_owner_upgraded: ephemeral_owner_upgraded
        }
      end)
      |> transaction_result()
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :forbidden}
    end
  end

  def convert_account(_attrs, _guest_subject), do: {:error, :forbidden}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

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

  defp lock_conversion_conversation!(snapshot) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.id == ^snapshot.conversation_id and
            conversation.tenant_id == ^snapshot.tenant_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:forbidden)
  end

  defp lock_conversion_link!(snapshot) do
    Repo.one(
      from(link in GuestLink,
        where:
          link.id == ^snapshot.guest_link_id and link.tenant_id == ^snapshot.tenant_id and
            link.conversation_id == ^snapshot.conversation_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:forbidden)
  end

  defp ensure_convertible!(conversation, link, admission, membership, timestamp) do
    valid? =
      is_nil(conversation.archived_at) and conversation.kind in [:group, :channel] and
        link.conversation_id == conversation.id and is_nil(link.revoked_at) and
        DateTime.compare(link.expires_at, timestamp) == :gt and
        admission.guest_link_id == link.id and
        admission.conversation_id == conversation.id and is_nil(admission.revoked_at) and
        is_nil(admission.converted_at) and
        DateTime.compare(admission.expires_at, timestamp) == :gt and
        membership.id == admission.membership_id and is_nil(membership.left_at)

    if valid?, do: :ok, else: Repo.rollback(:forbidden)
  end

  defp require_conversion_email!(%GuestLink{conversion_email: nil}, _attrs),
    do: Repo.rollback(:guest_account_conversion_not_enabled)

  defp require_conversion_email!(%GuestLink{conversion_email: expected_email}, attrs) do
    if Token.normalize_email(value(attrs, :email)) == expected_email do
      expected_email
    else
      Repo.rollback(:guest_account_conversion_email_mismatch)
    end
  end

  defp require_conversion_verification!(link, admission, expected_email, attrs) do
    {valid_format?, candidate_secret} =
      Token.conversion_verification_secret(value(attrs, :verification_code))

    bound? =
      admission.tenant_id == link.tenant_id and
        admission.conversation_id == link.conversation_id and
        admission.guest_link_id == link.id and expected_email == link.conversion_email

    candidate_digest =
      Token.conversion_verification_digest(
        candidate_secret,
        link.tenant_id,
        link.conversation_id,
        link.id,
        expected_email
      )

    verified? =
      Token.secure_binary_match?(
        candidate_digest,
        link.conversion_verification_digest
      )

    if bound? and valid_format? and verified?,
      do: :ok,
      else: Repo.rollback(:guest_account_conversion_verification_failed)
  end

  defp convert_guest_identity(
         %GuestLink{purpose: :ephemeral_room},
         admission,
         attrs,
         guest_subject
       ) do
    if Application.get_env(:comms_core, :instant_rooms_enabled, false) do
      scoped_subject =
        guest_subject
        |> Map.put(:guest_authority_purpose, :ephemeral_room)
        |> Map.put(:guest_admission_id, admission.id)
        |> Map.put(:guest_conversation_id, admission.conversation_id)

      Accounts.convert_ephemeral_guest_account(attrs, scoped_subject)
    else
      {:error, :instant_rooms_unavailable}
    end
  end

  defp convert_guest_identity(%GuestLink{} = link, admission, attrs, guest_subject) do
    expected_email = require_conversion_email!(link, attrs)
    require_conversion_verification!(link, admission, expected_email, attrs)
    Accounts.convert_guest_account(attrs, guest_subject, expected_email)
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

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
