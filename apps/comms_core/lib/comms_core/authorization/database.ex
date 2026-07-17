defmodule CommsCore.Authorization.Database do
  @moduledoc """
  Temporary Calls-only authorization adapter.

  Non-media authorization is owned by the context that owns the protected
  state. This module remains solely for the explicitly deferred audio/video
  boundary and must be deleted in the separate Calls tranche.
  """

  @behaviour CommsCore.Authorization

  import Ecto.Query

  alias CommsCore.Accounts.{Device, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Repo

  @call_member_actions [:read_call]
  @audio_member_actions [:read_audio_call, :start_audio_call, :join_audio_call]
  @video_member_actions [:read_video_call, :start_video_call, :join_video_call]

  @impl true
  def authorize(action, subject, resource) when action in @call_member_actions do
    authorize_active_member(subject, resource)
  end

  def authorize(action, subject, resource) when action in @audio_member_actions do
    authorize_media_member(subject, resource, :audio)
  end

  def authorize(action, subject, resource) when action in @video_member_actions do
    authorize_media_member(subject, resource, :video)
  end

  def authorize(:end_audio_call, subject, resource),
    do: authorize_end(subject, resource, :audio)

  def authorize(:end_video_call, subject, resource),
    do: authorize_end(subject, resource, :video)

  def authorize(_action, _subject, _resource), do: {:error, :forbidden}

  defp authorize_active_member(subject, resource) do
    with {:ok, conversation_id} <- conversation_id(resource),
         true <- active_subject?(subject),
         %Membership{} <- active_membership(subject, conversation_id) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_media_member(subject, resource, media_kind) do
    with {:ok, conversation_id} <- conversation_id(resource),
         true <- active_subject?(subject),
         :ok <- calls_enabled(subject, media_kind),
         %Membership{} <- active_membership(subject, conversation_id) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_end(subject, resource, _media_kind) do
    with {:ok, conversation_id} <- conversation_id(resource),
         true <- active_subject?(subject),
         %Membership{} = membership <- active_membership(subject, conversation_id) do
      if value(subject, :user_id) == value(resource, :started_by_user_id) or
           membership.role in [:owner, :moderator] do
        :ok
      else
        {:error, :forbidden}
      end
    else
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp active_subject?(subject) do
    case {
      value(subject, :tenant_id),
      value(subject, :user_id),
      value(subject, :device_id),
      value(subject, :session_id)
    } do
      {tenant_id, user_id, device_id, session_id}
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) and
             is_binary(session_id) ->
        timestamp = now()

        Repo.exists?(
          from(s in Session,
            join: t in Tenant,
            on: t.id == s.tenant_id,
            join: u in User,
            on: u.id == s.user_id,
            join: d in Device,
            on: d.id == s.device_id,
            where:
              s.id == ^session_id and s.tenant_id == ^tenant_id and s.user_id == ^user_id and
                s.device_id == ^device_id and t.id == ^tenant_id and t.status == :active and
                u.id == ^user_id and u.tenant_id == ^tenant_id and u.status == :active and
                u.account_type == :human and d.id == ^device_id and d.tenant_id == ^tenant_id and
                d.user_id == ^user_id and is_nil(d.revoked_at) and is_nil(s.revoked_at) and
                s.expires_at > ^timestamp and s.absolute_expires_at > ^timestamp,
            select: true
          )
        )

      _ ->
        false
    end
  end

  defp active_membership(subject, conversation_id) do
    Repo.one(
      from(m in Membership,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          m.conversation_id == ^conversation_id and
            m.user_id == ^value(subject, :user_id) and
            m.tenant_id == ^value(subject, :tenant_id) and
            c.tenant_id == ^value(subject, :tenant_id) and
            is_nil(m.left_at) and is_nil(c.archived_at)
      )
    )
  end

  defp calls_enabled(subject, media_kind) do
    case Repo.get_by(TenantSettings, tenant_id: value(subject, :tenant_id)) do
      %TenantSettings{allow_audio_calls: false} when media_kind == :audio ->
        {:error, :audio_calls_disabled}

      %TenantSettings{allow_video_calls: false} when media_kind == :video ->
        {:error, :video_calls_disabled}

      _settings ->
        :ok
    end
  end

  defp conversation_id(resource) when is_map(resource) do
    case value(resource, :conversation_id) || value(resource, :id) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :missing_conversation}
    end
  end

  defp conversation_id(_resource), do: {:error, :missing_conversation}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
