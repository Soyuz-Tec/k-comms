defmodule CommsCore.AudioCalls.AuthorizationPolicy do
  @moduledoc false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.AccessGrant
  alias CommsCore.Administration
  alias CommsCore.Administration.CallPolicy
  alias CommsCore.AudioCalls.Access
  alias CommsCore.Conversations
  alias CommsCore.Conversations.CallMembership

  @call_member_actions [:read_call]
  @audio_member_actions [:read_audio_call, :start_audio_call, :join_audio_call]
  @video_member_actions [:read_video_call, :start_video_call, :join_video_call]
  @member_actions @call_member_actions ++ @audio_member_actions ++ @video_member_actions
  @end_actions [:end_audio_call, :end_video_call]

  @type action ::
          :read_call
          | :read_audio_call
          | :start_audio_call
          | :join_audio_call
          | :end_audio_call
          | :read_video_call
          | :start_video_call
          | :join_video_call
          | :end_video_call

  @spec authorize(action() | atom(), map(), map()) :: :ok | {:error, term()}
  def authorize(action, subject, resource) when action in @call_member_actions do
    with {:ok, conversation_id} <- conversation_id(resource),
         {:ok, %AccessGrant{} = grant} <- Accounts.access_grant(subject),
         {:ok, %CallMembership{}} <-
           Conversations.call_membership(grant.tenant_id, conversation_id, grant.user_id) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def authorize(action, subject, resource)
      when action in @audio_member_actions or action in @video_member_actions do
    with {:ok, conversation_id} <- conversation_id(resource),
         {:ok, %AccessGrant{} = grant} <- Accounts.access_grant(subject),
         {:ok, %CallPolicy{} = call_policy} <- Administration.call_policy(grant.tenant_id),
         :ok <- media_enabled(action, call_policy),
         {:ok, %CallMembership{}} <-
           Conversations.call_membership(grant.tenant_id, conversation_id, grant.user_id) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def authorize(action, subject, resource) when action in @end_actions do
    with {:ok, conversation_id} <- conversation_id(resource),
         {:ok, %AccessGrant{} = grant} <- Accounts.access_grant(subject),
         {:ok, %CallMembership{} = membership} <-
           Conversations.call_membership(grant.tenant_id, conversation_id, grant.user_id) do
      authorize_end(grant.user_id, membership.role, resource)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def authorize(_action, _subject, _resource), do: {:error, :forbidden}

  @doc false
  @spec lock_access(map(), Ecto.UUID.t(), :share | :update) ::
          {:ok, Access.t()} | {:error, :forbidden | :transaction_required}
  def lock_access(subject, conversation_id, lock_mode)
      when is_map(subject) and is_binary(conversation_id) and lock_mode in [:share, :update] do
    tenant_id = value(subject, :tenant_id)

    with true <- is_binary(tenant_id),
         {:ok, %CallPolicy{} = call_policy} <- Administration.lock_call_policy(tenant_id),
         {:ok, _conversation} <-
           Conversations.lock_call_conversation(tenant_id, conversation_id, lock_mode),
         {:ok, %AccessGrant{} = grant} <- Accounts.lock_access_grant(subject),
         true <- grant.tenant_id == tenant_id,
         {:ok, %CallMembership{} = membership} <-
           Conversations.lock_call_membership(tenant_id, conversation_id, grant.user_id) do
      {:ok,
       %Access{
         tenant_id: grant.tenant_id,
         user_id: grant.user_id,
         device_id: grant.device_id,
         session_id: grant.session_id,
         conversation_id: membership.conversation_id,
         membership_role: membership.role,
         allow_audio_calls: call_policy.allow_audio_calls,
         allow_video_calls: call_policy.allow_video_calls
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def lock_access(_subject, _conversation_id, _lock_mode), do: {:error, :forbidden}

  @doc false
  @spec authorize_access(action() | atom(), Access.t(), map()) :: :ok | {:error, term()}
  def authorize_access(action, %Access{} = access, resource) when action in @member_actions do
    with {:ok, conversation_id} <- conversation_id(resource),
         true <- conversation_id == access.conversation_id,
         :ok <- media_enabled(action, access) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def authorize_access(action, %Access{} = access, resource) when action in @end_actions do
    with {:ok, conversation_id} <- conversation_id(resource),
         true <- conversation_id == access.conversation_id do
      authorize_end(access.user_id, access.membership_role, resource)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def authorize_access(_action, _access, _resource), do: {:error, :forbidden}

  defp media_enabled(action, policy) when action in @audio_member_actions do
    if policy.allow_audio_calls, do: :ok, else: {:error, :audio_calls_disabled}
  end

  defp media_enabled(action, policy) when action in @video_member_actions do
    if policy.allow_video_calls, do: :ok, else: {:error, :video_calls_disabled}
  end

  defp media_enabled(_action, _policy), do: :ok

  defp authorize_end(user_id, membership_role, resource) do
    if user_id == value(resource, :started_by_user_id) or
         membership_role in [:owner, :moderator] do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp conversation_id(resource) when is_map(resource) do
    case value(resource, :conversation_id) || value(resource, :id) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :missing_conversation}
    end
  end

  defp conversation_id(_resource), do: {:error, :missing_conversation}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
