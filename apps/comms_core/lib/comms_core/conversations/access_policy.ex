defmodule CommsCore.Conversations.AccessPolicy do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Administration, Repo, ServiceAccounts}
  alias CommsCore.Conversations.{AvailabilityQuery, Conversation, Membership}

  def authorize_service_access(subject, required_scope, conversation_id)
      when is_map(subject) and is_binary(required_scope) and is_binary(conversation_id) do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         :ok <- ServiceAccounts.authorize_service(subject, required_scope),
         true <- active_service_membership?(subject, conversation_id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize_service_access(_subject, _required_scope, _conversation_id),
    do: {:error, :forbidden}

  def authorize_create(subject) when is_map(subject) do
    with {:ok, %{account_type: :human, access_scope: :workspace}} <-
           Accounts.access_grant(subject) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize_create(_subject), do: {:error, :forbidden}

  def authorize_discovery(subject) when is_map(subject) do
    with {:ok, %{account_type: :human, access_scope: :workspace}} <-
           Accounts.access_grant(subject),
         :ok <- public_channels_enabled(subject) do
      :ok
    else
      {:error, :public_channels_disabled} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def authorize_discovery(_subject), do: {:error, :forbidden}

  def authorize_join(conversation_id, subject),
    do: authorize_public_channel(:join, conversation_id, subject)

  def authorize_leave(conversation_id, subject),
    do: authorize_public_channel(:leave, conversation_id, subject)

  def authorize_read(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  def authorize_send_message(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  def authorize_mark_read(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  def authorize_react_message(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  def authorize_upload_attachment(conversation_id, subject),
    do: authorize_active_membership(conversation_id, subject)

  def authorize_manage(conversation_id, subject),
    do: authorize_management(:manage_conversation, conversation_id, subject)

  def authorize_manage_ownership(conversation_id, subject),
    do: authorize_management(:manage_conversation_ownership, conversation_id, subject)

  def active_membership_authorization_query(%CommsCore.Accounts.AccessGrant{
        tenant_id: tenant_id,
        user_id: user_id
      }) do
    active_membership_authorization_query(tenant_id, user_id)
  end

  def active_service_membership_authorization_query(subject, required_scope)
      when is_map(subject) and is_binary(required_scope) do
    with :ok <- ServiceAccounts.authorize_service(subject, required_scope),
         {:ok, tenant_id} <- Ecto.UUID.cast(value(subject, :tenant_id)),
         {:ok, user_id} <- Ecto.UUID.cast(value(subject, :user_id)) do
      {:ok, active_membership_authorization_query(tenant_id, user_id)}
    else
      _ -> {:error, :forbidden}
    end
  end

  def active_service_membership_authorization_query(_subject, _required_scope),
    do: {:error, :forbidden}

  def active_conversation_member?(
        %CommsCore.Accounts.AccessGrant{} = grant,
        conversation_id
      ) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, conversation_id} ->
        grant
        |> active_membership_authorization_query()
        |> subquery()
        |> where([authorization], authorization.conversation_id == ^conversation_id)
        |> Repo.exists?()

      :error ->
        false
    end
  end

  @doc false
  def validate_public_channel(subject, :channel, :tenant),
    do: public_channels_enabled(subject)

  def validate_public_channel(_subject, _kind, _visibility), do: :ok

  defp active_membership_authorization_query(tenant_id, user_id) do
    unavailable_conversations = AvailabilityQuery.unavailable_ephemeral_conversation_ids(now())

    from(conversation in Conversation,
      join: membership in Membership,
      on:
        membership.conversation_id == conversation.id and
          membership.tenant_id == conversation.tenant_id,
      where:
        conversation.tenant_id == ^tenant_id and membership.user_id == ^user_id and
          is_nil(membership.left_at) and is_nil(conversation.archived_at) and
          conversation.id not in subquery(unavailable_conversations),
      select: %{
        conversation_id: conversation.id,
        membership_role: membership.role
      }
    )
  end

  defp authorize_public_channel(action, conversation_id, subject)
       when action in [:join, :leave] and is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         :ok <- require_workspace_for_public_join(action, grant),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         %Conversation{kind: :channel, visibility: :tenant, archived_at: nil} <-
           Repo.get_by(Conversation,
             id: conversation_id,
             tenant_id: grant.tenant_id
           ),
         :ok <- maybe_require_public_channels_enabled(action, subject) do
      :ok
    else
      {:error, :public_channels_disabled} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_public_channel(_action, _conversation_id, _subject),
    do: {:error, :forbidden}

  defp authorize_active_membership(conversation_id, subject)
       when is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         %Membership{} <- active_membership(grant, conversation_id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_active_membership(_conversation_id, _subject),
    do: {:error, :forbidden}

  defp authorize_management(action, conversation_id, subject)
       when action in [:manage_conversation, :manage_conversation_ownership] and
              is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant} <- Accounts.access_grant(subject) do
      authorization =
        with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
             %Conversation{} = conversation <-
               Repo.get_by(Conversation,
                 id: conversation_id,
                 tenant_id: grant.tenant_id
               ) do
          membership = active_membership(grant, conversation_id)

          case {action, grant.role, membership, conversation} do
            {:manage_conversation, _tenant_role, %Membership{role: role}, _conversation}
            when role in [:owner, :moderator] ->
              :ok

            {:manage_conversation_ownership, _tenant_role, %Membership{role: :owner},
             _conversation} ->
              :ok

            {_action, role, _membership, %Conversation{kind: :channel, visibility: :tenant}}
            when role in [:owner, :admin] ->
              :ok

            _ ->
              {:error, :forbidden}
          end
        else
          _ -> {:error, :forbidden}
        end

      case authorization do
        :ok -> :ok
        {:error, :forbidden} -> deny_conversation_management(action, grant, subject)
      end
    else
      {:error, _reason} ->
        Accounts.audit_authorization_denial(action, subject, :forbidden)
    end
  end

  defp authorize_management(_action, _conversation_id, _subject),
    do: {:error, :forbidden}

  defp active_membership(grant, conversation_id) do
    unavailable_conversations = AvailabilityQuery.unavailable_ephemeral_conversation_ids(now())

    Repo.one(
      from(membership in Membership,
        join: conversation in Conversation,
        on:
          conversation.id == membership.conversation_id and
            conversation.tenant_id == membership.tenant_id,
        where:
          membership.conversation_id == ^conversation_id and
            membership.user_id == ^grant.user_id and
            membership.tenant_id == ^grant.tenant_id and
            conversation.tenant_id == ^grant.tenant_id and
            is_nil(membership.left_at) and is_nil(conversation.archived_at) and
            conversation.id not in subquery(unavailable_conversations)
      )
    )
  end

  defp maybe_require_public_channels_enabled(:join, subject),
    do: public_channels_enabled(subject)

  defp maybe_require_public_channels_enabled(:leave, _subject), do: :ok

  defp require_workspace_for_public_join(:join, %{account_type: :human, access_scope: :workspace}),
       do: :ok

  defp require_workspace_for_public_join(:leave, _grant), do: :ok
  defp require_workspace_for_public_join(_action, _grant), do: {:error, :forbidden}

  defp public_channels_enabled(subject) do
    case Administration.member_capabilities(subject) do
      {:ok, %{allow_public_channels: false}} -> {:error, :public_channels_disabled}
      {:ok, %{allow_public_channels: true}} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp deny_conversation_management(action, _grant, subject),
    do: Accounts.audit_authorization_denial(action, subject, :forbidden)

  defp active_service_membership?(subject, conversation_id) do
    Repo.exists?(
      from(membership in Membership,
        join: conversation in Conversation,
        on:
          conversation.id == membership.conversation_id and
            conversation.tenant_id == membership.tenant_id,
        where:
          membership.tenant_id == ^value(subject, :tenant_id) and
            membership.user_id == ^value(subject, :user_id) and
            membership.conversation_id == ^conversation_id and is_nil(membership.left_at) and
            is_nil(conversation.archived_at)
      )
    )
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
