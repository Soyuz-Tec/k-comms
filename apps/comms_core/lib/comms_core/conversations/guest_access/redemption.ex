defmodule CommsCore.Conversations.GuestAccess.Redemption do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{
    Accounts,
    Administration,
    AdmissionQuotas,
    Audit,
    Repo
  }

  alias CommsCore.Conversations.{
    Conversation,
    GuestAdmission,
    GuestLink,
    Membership,
    Projector
  }

  alias CommsCore.Conversations.GuestAccess.{
    Projection,
    Scheduler,
    Token
  }

  def preview_link(token) when is_binary(token) do
    with {:ok, link_id, secret} <- Token.parse(token),
         %GuestLink{} = link <- Repo.get(GuestLink, link_id),
         true <- Token.secure_digest_match?(secret, link.token_digest),
         :ok <- available_link(link, now()),
         %Conversation{} = conversation <- available_guest_conversation(link),
         {:ok, _tenant} <- Administration.active_tenant(link.tenant_id) do
      {:ok, Projection.preview(conversation, link)}
    else
      _ -> {:error, :guest_link_unavailable}
    end
  end

  def preview_link(_token), do: {:error, :guest_link_unavailable}

  def redeem_link(token, attrs) when is_binary(token) and is_map(attrs) do
    with {:ok, link_id, secret} <- Token.parse(token),
         %GuestLink{tenant_id: tenant_id, conversation_id: conversation_id} = link_snapshot <-
           Repo.get(GuestLink, link_id),
         true <- Token.secure_digest_match?(secret, link_snapshot.token_digest),
         {:ok, display_name} <- display_name(attrs),
         {:ok, device} <- device(attrs) do
      Repo.transaction(fn ->
        policy = admission_policy!(tenant_id)
        conversation = lock_available_guest_conversation!(tenant_id, conversation_id)
        link = lock_available_link!(tenant_id, conversation.id, link_id, secret)
        timestamp = now()
        available_link!(link, timestamp)
        quota_ok!(ensure_conversation_member_capacity(policy, conversation))

        authentication =
          provision_guest_identity!(%{
            tenant_id: tenant_id,
            display_name: display_name,
            device: device,
            expires_at: link.expires_at,
            request_id: value(attrs, :request_id)
          })

        guest_user_id = authentication.user.id
        session_id = authentication.session_id
        history_from_sequence = conversation.next_sequence

        membership =
          %Membership{}
          |> Membership.changeset(%{
            tenant_id: tenant_id,
            conversation_id: conversation.id,
            user_id: guest_user_id,
            role: :member,
            joined_at: timestamp,
            left_at: nil,
            last_read_sequence: max(history_from_sequence - 1, 0)
          })
          |> insert_or_rollback()

        admission =
          %GuestAdmission{}
          |> GuestAdmission.changeset(%{
            tenant_id: tenant_id,
            conversation_id: conversation.id,
            guest_link_id: link.id,
            guest_user_id: guest_user_id,
            membership_id: membership.id,
            session_id: session_id,
            admitted_at: timestamp,
            expires_at: link.expires_at,
            history_from_sequence: history_from_sequence
          })
          |> insert_or_rollback()

        link
        |> GuestLink.changeset(%{use_count: link.use_count + 1})
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

        Scheduler.enqueue_expiry!(admission)

        audit!(
          tenant_id,
          guest_user_id,
          "conversation.guest.admitted",
          "conversation_guest_admission",
          admission.id,
          %{
            conversation_id: conversation.id,
            guest_link_id: link.id,
            history_from_sequence: history_from_sequence,
            expires_at: DateTime.to_iso8601(link.expires_at)
          },
          value(attrs, :request_id)
        )

        %{
          authentication: authentication,
          conversation: Projector.conversation(conversation),
          admission: Projection.admission(admission),
          capabilities: guest_capabilities!(tenant_id, link.conversion_email, link.purpose)
        }
      end)
      |> transaction_result()
    else
      {:error, reason} when reason in [:invalid_guest_display_name, :invalid_guest_device] ->
        {:error, reason}

      _ ->
        {:error, :guest_link_unavailable}
    end
  end

  def redeem_link(_token, _attrs), do: {:error, :guest_link_unavailable}

  def resolve_access(subject, conversation_id)
      when is_map(subject) and is_binary(conversation_id) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)
    session_id = value(subject, :session_id)
    timestamp = now()

    case Repo.one(
           from(admission in GuestAdmission,
             join: link in GuestLink,
             on:
               link.id == admission.guest_link_id and
                 link.tenant_id == admission.tenant_id and
                 link.conversation_id == admission.conversation_id,
             join: membership in Membership,
             on:
               membership.id == admission.membership_id and
                 membership.tenant_id == admission.tenant_id and
                 membership.conversation_id == admission.conversation_id and
                 membership.user_id == admission.guest_user_id,
             join: conversation in Conversation,
             on:
               conversation.id == admission.conversation_id and
                 conversation.tenant_id == admission.tenant_id,
             where:
               admission.tenant_id == ^tenant_id and
                 admission.conversation_id == ^conversation_id and
                 admission.guest_user_id == ^user_id and admission.session_id == ^session_id and
                 is_nil(admission.revoked_at) and is_nil(admission.converted_at) and
                 admission.expires_at > ^timestamp and
                 is_nil(link.revoked_at) and link.expires_at > ^timestamp and
                 is_nil(membership.left_at) and is_nil(conversation.archived_at),
             order_by: [desc: admission.admitted_at],
             limit: 1,
             select: %{
               admission_id: admission.id,
               guest_link_id: admission.guest_link_id,
               membership_id: admission.membership_id,
               tenant_id: admission.tenant_id,
               conversation_id: admission.conversation_id,
               user_id: admission.guest_user_id,
               session_id: admission.session_id,
               admitted_at: admission.admitted_at,
               expires_at: admission.expires_at,
               converted_at: admission.converted_at,
               history_from_sequence: admission.history_from_sequence,
               conversion_email: link.conversion_email,
               link_purpose: link.purpose
             }
           )
         ) do
      nil ->
        {:error, :forbidden}

      access ->
        case guest_capabilities(
               access.tenant_id,
               access.conversion_email,
               access.link_purpose
             ) do
          {:ok, capabilities} ->
            {:ok,
             access
             |> Map.delete(:conversion_email)
             |> Map.delete(:link_purpose)
             |> Map.put(:capabilities, capabilities)}

          {:error, _reason} ->
            {:error, :forbidden}
        end
    end
  end

  def resolve_access(_subject, _conversation_id), do: {:error, :forbidden}

  def scope_for_session(session_id) when is_binary(session_id) do
    timestamp = now()

    case Repo.one(
           from(admission in GuestAdmission,
             join: link in GuestLink,
             on:
               link.id == admission.guest_link_id and
                 link.tenant_id == admission.tenant_id and
                 link.conversation_id == admission.conversation_id,
             join: membership in Membership,
             on:
               membership.id == admission.membership_id and
                 membership.tenant_id == admission.tenant_id and
                 membership.conversation_id == admission.conversation_id and
                 membership.user_id == admission.guest_user_id,
             join: conversation in Conversation,
             on:
               conversation.id == admission.conversation_id and
                 conversation.tenant_id == admission.tenant_id,
             where:
               admission.session_id == ^session_id and is_nil(admission.revoked_at) and
                 is_nil(admission.converted_at) and admission.expires_at > ^timestamp and
                 is_nil(link.revoked_at) and link.expires_at > ^timestamp and
                 is_nil(membership.left_at) and is_nil(conversation.archived_at),
             limit: 1,
             select: %{
               admission_id: admission.id,
               guest_link_id: admission.guest_link_id,
               membership_id: admission.membership_id,
               tenant_id: admission.tenant_id,
               conversation_id: admission.conversation_id,
               user_id: admission.guest_user_id,
               session_id: admission.session_id,
               admitted_at: admission.admitted_at,
               expires_at: admission.expires_at,
               converted_at: admission.converted_at,
               history_from_sequence: admission.history_from_sequence,
               conversion_email: link.conversion_email,
               link_purpose: link.purpose,
               conversation: conversation
             }
           )
         ) do
      nil ->
        {:error, :forbidden}

      %{conversation: conversation} = scope ->
        case guest_capabilities(
               scope.tenant_id,
               scope.conversion_email,
               scope.link_purpose
             ) do
          {:ok, capabilities} ->
            {:ok,
             scope
             |> Map.delete(:conversion_email)
             |> Map.delete(:link_purpose)
             |> Map.put(:conversation, Projector.conversation(conversation))
             |> Map.put(:capabilities, capabilities)}

          {:error, _reason} ->
            {:error, :forbidden}
        end
    end
  end

  def scope_for_session(_session_id), do: {:error, :forbidden}

  defp display_name(attrs) do
    case value(attrs, :display_name) do
      name when is_binary(name) ->
        name = String.trim(name)

        if String.length(name) in 1..120,
          do: {:ok, name},
          else: {:error, :invalid_guest_display_name}

      _ ->
        {:error, :invalid_guest_display_name}
    end
  end

  defp device(attrs) do
    case value(attrs, :device) do
      device when is_map(device) -> {:ok, device}
      _ -> {:error, :invalid_guest_device}
    end
  end

  defp available_link(%GuestLink{} = link, timestamp) do
    cond do
      link.revoked_at -> {:error, :guest_link_unavailable}
      DateTime.compare(link.expires_at, timestamp) != :gt -> {:error, :guest_link_unavailable}
      link.use_count >= link.max_uses -> {:error, :guest_link_unavailable}
      true -> :ok
    end
  end

  defp available_guest_conversation(link) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.id == ^link.conversation_id and
            conversation.tenant_id == ^link.tenant_id and
            conversation.kind in [:group, :channel] and is_nil(conversation.archived_at)
      )
    )
  end

  defp available_link!(link, timestamp) do
    case available_link(link, timestamp) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_available_link!(tenant_id, conversation_id, link_id, secret) do
    link =
      Repo.one(
        from(link in GuestLink,
          where:
            link.id == ^link_id and link.tenant_id == ^tenant_id and
              link.conversation_id == ^conversation_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:guest_link_unavailable)

    if Token.secure_digest_match?(secret, link.token_digest) do
      link
    else
      Repo.rollback(:guest_link_unavailable)
    end
  end

  defp lock_available_guest_conversation!(tenant_id, conversation_id) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.id == ^conversation_id and
            conversation.tenant_id == ^tenant_id and
            conversation.kind in [:group, :channel] and is_nil(conversation.archived_at),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:guest_link_unavailable)
  end

  defp provision_guest_identity!(command) do
    case Accounts.provision_guest_identity(command) do
      {:ok, authentication} -> authentication
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp guest_capabilities(tenant_id, conversion_email, purpose) do
    case Administration.call_policy(tenant_id) do
      {:ok, policy} ->
        {:ok,
         %{
           allow_audio_calls: policy.allow_audio_calls,
           allow_video_calls: policy.allow_video_calls,
           conversion_enabled: purpose == :ephemeral_room or not is_nil(conversion_email),
           self_service_conversion: purpose == :ephemeral_room,
           email_hint: Token.email_hint(conversion_email)
         }}

      {:error, _reason} ->
        {:error, :forbidden}
    end
  end

  defp guest_capabilities!(tenant_id, conversion_email, purpose) do
    case guest_capabilities(tenant_id, conversion_email, purpose) do
      {:ok, capabilities} -> capabilities
      {:error, reason} -> Repo.rollback(reason)
    end
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

  defp ensure_conversation_member_capacity(policy, conversation) do
    timestamp = now()

    current_active_members =
      Membership
      |> join(
        :left,
        [membership],
        admission in GuestAdmission,
        on:
          admission.tenant_id == membership.tenant_id and
            admission.membership_id == membership.id and is_nil(admission.converted_at)
      )
      |> where(
        [membership, admission],
        membership.tenant_id == ^conversation.tenant_id and
          membership.conversation_id == ^conversation.id and is_nil(membership.left_at) and
          (is_nil(admission.id) or
             (is_nil(admission.revoked_at) and admission.expires_at > ^timestamp))
      )
      |> Repo.aggregate(:count)

    AdmissionQuotas.check_conversation_member_capacity(policy, current_active_members)
  end

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)

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

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
