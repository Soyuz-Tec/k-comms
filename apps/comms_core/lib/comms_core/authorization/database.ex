defmodule CommsCore.Authorization.Database do
  @behaviour CommsCore.Authorization

  import Ecto.Query

  alias CommsCore.Accounts.{Device, Session, Tenant, User}
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.Audit.AuditEvent
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Messaging.Message
  alias CommsCore.Repo

  @member_actions [
    :read_conversation,
    :send_message,
    :mark_read,
    :react_message,
    :upload_attachment
  ]

  @platform_roles [:platform_operator, :support_operator, :security_operator]

  def authorize(:create_conversation, subject, _resource) do
    if active_subject?(subject), do: :ok, else: {:error, :forbidden}
  end

  def authorize(:discover_public_channels, subject, _resource) do
    with true <- active_subject?(subject),
         :ok <- public_channels_enabled(value(subject, :tenant_id)) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def authorize(action, subject, resource)
      when action in [:join_conversation, :leave_conversation] do
    with {:ok, conversation_id} <- conversation_id(resource),
         true <- active_subject?(subject),
         %Conversation{kind: :channel, visibility: :tenant, archived_at: nil} <-
           Repo.get_by(Conversation,
             id: conversation_id,
             tenant_id: value(subject, :tenant_id)
           ),
         :ok <- maybe_require_public_channels_enabled(action, value(subject, :tenant_id)) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def authorize(:read_tenant_capabilities, subject, _resource) do
    if active_subject?(subject), do: :ok, else: {:error, :forbidden}
  end

  def authorize(:receive_user_events, subject, resource) do
    if active_subject?(subject) and value(subject, :user_id) == value(resource, :user_id),
      do: :ok,
      else: {:error, :forbidden}
  end

  @impl true
  def authorize(action, subject, resource) when action in @member_actions do
    with {:ok, conversation_id} <- conversation_id(resource),
         true <- active_subject?(subject),
         %Membership{} <- active_membership(subject, conversation_id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(:manage_conversation, subject, resource) do
    with {:ok, conversation_id} <- conversation_id(resource),
         true <- active_subject?(subject),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation,
             id: conversation_id,
             tenant_id: value(subject, :tenant_id)
           ) do
      case {active_user_role(subject), active_membership(subject, conversation_id), conversation} do
        {_tenant_role, %Membership{role: role}, _conversation}
        when role in [:owner, :moderator] ->
          :ok

        {role, _membership, %Conversation{kind: :channel, visibility: :tenant}}
        when role in [:owner, :admin] ->
          :ok

        _ ->
          deny_privileged(:manage_conversation, subject, :forbidden)
      end
    else
      _ -> deny_privileged(:manage_conversation, subject, :forbidden)
    end
  end

  def authorize(:edit_message, subject, %Message{} = message) do
    with true <- active_subject?(subject),
         true <- same_tenant?(subject, message),
         %Membership{} <- active_membership(subject, message.conversation_id),
         true <- value(subject, :user_id) == message.sender_user_id,
         true <- message.status == :active,
         :ok <- enforce_edit_window(message) do
      :ok
    else
      {:error, :edit_window_expired} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def authorize(:delete_message, subject, %Message{} = message) do
    with true <- active_subject?(subject),
         true <- same_tenant?(subject, message),
         %Membership{} <- active_membership(subject, message.conversation_id) do
      if value(subject, :user_id) == message.sender_user_id do
        :ok
      else
        authorize(:manage_conversation, subject, %{id: message.conversation_id})
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(:administer_tenant, subject, _resource) do
    with true <- active_subject?(subject),
         role when role in [:owner, :admin] <- active_user_role(subject) do
      :ok
    else
      _ -> deny_privileged(:administer_tenant, subject, :forbidden)
    end
  end

  def authorize(:manage_user_lifecycle, subject, _resource) do
    with true <- active_subject?(subject),
         :ok <- require_role(subject, [:owner, :admin]),
         :ok <- require_step_up(subject) do
      :ok
    else
      {:error, reason} -> deny_privileged(:manage_user_lifecycle, subject, reason)
      _ -> deny_privileged(:manage_user_lifecycle, subject, :forbidden)
    end
  end

  def authorize(action, subject, _resource)
      when action in [:manage_tenant_settings, :manage_integrations, :manage_attachment_safety] do
    with true <- active_subject?(subject),
         :ok <- require_role(subject, [:owner, :admin]),
         :ok <- require_step_up(subject) do
      :ok
    else
      {:error, reason} -> deny_privileged(action, subject, reason)
      _ -> deny_privileged(action, subject, :forbidden)
    end
  end

  def authorize(:manage_moderation, subject, _resource) do
    with true <- active_subject?(subject),
         :ok <- require_role(subject, [:owner, :admin, :moderator, :compliance_admin]),
         :ok <- require_step_up(subject) do
      :ok
    else
      {:error, reason} -> deny_privileged(:manage_moderation, subject, reason)
      _ -> deny_privileged(:manage_moderation, subject, :forbidden)
    end
  end

  def authorize(:manage_sessions, subject, _resource) do
    with true <- active_subject?(subject),
         :ok <- require_role(subject, [:owner, :security_admin]),
         :ok <- require_step_up(subject) do
      :ok
    else
      {:error, reason} -> deny_privileged(:manage_sessions, subject, reason)
      _ -> deny_privileged(:manage_sessions, subject, :forbidden)
    end
  end

  def authorize(:audit_tenant, subject, _resource) do
    with true <- active_subject?(subject),
         :ok <- require_role(subject, [:owner, :compliance_admin, :security_admin]),
         :ok <- require_step_up(subject) do
      :ok
    else
      {:error, reason} -> deny_privileged(:audit_tenant, subject, reason)
      _ -> deny_privileged(:audit_tenant, subject, :forbidden)
    end
  end

  def authorize(:govern_tenant, subject, _resource) do
    with true <- active_subject?(subject),
         :ok <- require_role(subject, [:owner, :compliance_admin]),
         :ok <- require_step_up(subject) do
      :ok
    else
      {:error, reason} -> deny_privileged(:govern_tenant, subject, reason)
      _ -> deny_privileged(:govern_tenant, subject, :forbidden)
    end
  end

  def authorize(:moderate_tenant, subject, _resource) do
    with true <- active_subject?(subject),
         role when role in [:owner, :admin, :moderator, :compliance_admin] <-
           active_user_role(subject) do
      :ok
    else
      _ -> deny_privileged(:moderate_tenant, subject, :forbidden)
    end
  end

  def authorize(:report_moderation, subject, _resource) do
    if active_subject?(subject), do: :ok, else: {:error, :forbidden}
  end

  def authorize(:view_platform_operations, subject, _resource) do
    with true <- active_subject?(subject),
         role when role in @platform_roles <- active_platform_role(subject),
         ^role <- normalized_platform_role(value(subject, :platform_role)) do
      :ok
    else
      _ -> deny_privileged(:view_platform_operations, subject, :forbidden)
    end
  end

  def authorize(:operate_platform, subject, _resource) do
    with true <- active_subject?(subject),
         :platform_operator <- active_platform_role(subject),
         :platform_operator <- normalized_platform_role(value(subject, :platform_role)) do
      :ok
    else
      _ -> deny_privileged(:operate_platform, subject, :forbidden)
    end
  end

  def authorize(_, _, _), do: {:error, :forbidden}

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
        query =
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
                u.account_type == :human and
                d.id == ^device_id and d.tenant_id == ^tenant_id and d.user_id == ^user_id and
                is_nil(d.revoked_at) and is_nil(s.revoked_at) and s.expires_at > ^now(),
            select: true
          )

        Repo.exists?(query)

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

  defp active_user_role(subject) do
    case Repo.get_by(User,
           id: value(subject, :user_id),
           tenant_id: value(subject, :tenant_id),
           status: :active,
           account_type: :human
         ) do
      %User{role: role} -> role
      nil -> nil
    end
  end

  defp active_platform_role(subject) do
    case Repo.get_by(User,
           id: value(subject, :user_id),
           tenant_id: value(subject, :tenant_id),
           status: :active,
           account_type: :human
         ) do
      %User{platform_role: role} -> role
      nil -> nil
    end
  end

  defp normalized_platform_role(role) when role in @platform_roles, do: role

  defp normalized_platform_role(role) when is_binary(role) do
    Enum.find(@platform_roles, &(Atom.to_string(&1) == role))
  end

  defp normalized_platform_role(_role), do: nil

  defp recent_step_up?(subject) do
    ttl = Application.get_env(:comms_core, :step_up_ttl_seconds, 300)
    threshold = DateTime.add(now(), -ttl, :second)

    Repo.exists?(
      from(s in Session,
        where:
          s.id == ^value(subject, :session_id) and
            s.tenant_id == ^value(subject, :tenant_id) and
            s.user_id == ^value(subject, :user_id) and is_nil(s.revoked_at) and
            not is_nil(s.step_up_at) and s.step_up_at >= ^threshold
      )
    )
  end

  defp require_role(subject, allowed) do
    if active_user_role(subject) in allowed, do: :ok, else: {:error, :forbidden}
  end

  defp require_step_up(subject) do
    if recent_step_up?(subject), do: :ok, else: {:error, :step_up_required}
  end

  defp maybe_require_public_channels_enabled(:join_conversation, tenant_id),
    do: public_channels_enabled(tenant_id)

  # Disabling public channels must stop discovery and new joins, but it must not
  # trap an existing member in a channel they are still entitled to leave.
  defp maybe_require_public_channels_enabled(:leave_conversation, _tenant_id), do: :ok

  defp public_channels_enabled(tenant_id) do
    case Repo.get_by(TenantSettings, tenant_id: tenant_id) do
      %TenantSettings{allow_public_channels: false} -> {:error, :public_channels_disabled}
      _ -> :ok
    end
  end

  defp within_edit_window?(%Message{} = message) do
    seconds =
      case Repo.get_by(TenantSettings, tenant_id: message.tenant_id) do
        %TenantSettings{message_edit_window_seconds: value} -> value
        nil -> 86_400
      end

    seconds > 0 and
      DateTime.compare(message.inserted_at, DateTime.add(now(), -seconds, :second)) != :lt
  end

  defp enforce_edit_window(message) do
    if within_edit_window?(message), do: :ok, else: {:error, :edit_window_expired}
  end

  defp deny_privileged(action, subject, reason) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    with {:ok, _tenant_uuid} <- Ecto.UUID.cast(tenant_id),
         {:ok, _user_uuid} <- Ecto.UUID.cast(user_id),
         true <-
           Repo.exists?(from(u in User, where: u.id == ^user_id and u.tenant_id == ^tenant_id)) do
      %AuditEvent{}
      |> AuditEvent.changeset(%{
        tenant_id: tenant_id,
        actor_user_id: user_id,
        action: "authorization.denied",
        resource_type: "permission",
        resource_id: tenant_id,
        metadata: %{permission: action, reason: reason},
        request_id: value(subject, :request_id)
      })
      |> Repo.insert()
    end

    {:error, reason}
  end

  defp conversation_id(%Conversation{id: id}), do: {:ok, id}
  defp conversation_id(%Message{conversation_id: id}), do: {:ok, id}

  defp conversation_id(resource) when is_map(resource) do
    case value(resource, :conversation_id) || value(resource, :id) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :missing_conversation}
    end
  end

  defp conversation_id(_), do: {:error, :missing_conversation}

  defp same_tenant?(subject, resource) do
    value(subject, :tenant_id) == Map.get(resource, :tenant_id)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
