defmodule CommsCore.AdmissionQuotas do
  @moduledoc """
  Central, tenant-safe admission limits for identities, conversations, and memberships.

  Every mutating check requires an existing database transaction and takes the same
  tenant-scoped PostgreSQL transaction advisory lock. This deliberately serializes
  quota admissions and limit changes for one tenant while allowing different tenants
  to progress independently.
  """

  import Ecto.Query

  alias CommsCore.Accounts.User
  alias CommsCore.Administration.TenantSettings
  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.Repo

  @lock_prefix "k-comms:tenant-admission:v1:"

  def lock_tenant(tenant_id) when is_binary(tenant_id) do
    if Repo.in_transaction?() do
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))",
        [@lock_prefix <> tenant_id]
      )

      :ok
    else
      {:error, :quota_transaction_required}
    end
  end

  def lock_tenant(_), do: {:error, :quota_transaction_required}

  def ensure_active_user_capacity(tenant_id, increment \\ 1)
      when is_binary(tenant_id) and is_integer(increment) and increment > 0 do
    with :ok <- lock_tenant(tenant_id) do
      limit = settings(tenant_id).max_active_users

      current =
        User
        |> where([user], user.tenant_id == ^tenant_id and user.status == :active)
        |> Repo.aggregate(:count)

      ensure_capacity(current, increment, limit, :active_user_quota_exceeded)
    end
  end

  def ensure_conversation_creation(tenant_id, initial_member_count)
      when is_binary(tenant_id) and is_integer(initial_member_count) and
             initial_member_count > 0 do
    with :ok <- lock_tenant(tenant_id) do
      limits = settings(tenant_id)

      current =
        Conversation
        |> where(
          [conversation],
          conversation.tenant_id == ^tenant_id and is_nil(conversation.archived_at)
        )
        |> Repo.aggregate(:count)

      with :ok <-
             ensure_capacity(
               current,
               1,
               limits.max_active_conversations,
               :active_conversation_quota_exceeded
             ) do
        ensure_capacity(
          0,
          initial_member_count,
          limits.max_conversation_members,
          :conversation_member_quota_exceeded
        )
      end
    end
  end

  def ensure_conversation_member_capacity(tenant_id, conversation_id, increment \\ 1)
      when is_binary(tenant_id) and is_binary(conversation_id) and is_integer(increment) and
             increment > 0 do
    with :ok <- lock_tenant(tenant_id) do
      limit = settings(tenant_id).max_conversation_members

      current =
        Membership
        |> join(:inner, [membership], conversation in Conversation,
          on:
            conversation.id == membership.conversation_id and
              conversation.tenant_id == membership.tenant_id
        )
        |> where(
          [membership, conversation],
          membership.tenant_id == ^tenant_id and
            membership.conversation_id == ^conversation_id and
            conversation.tenant_id == ^tenant_id and is_nil(conversation.archived_at) and
            is_nil(membership.left_at)
        )
        |> Repo.aggregate(:count)

      ensure_capacity(current, increment, limit, :conversation_member_quota_exceeded)
    end
  end

  def usage(tenant_id) when is_binary(tenant_id) do
    limits = limits(settings(tenant_id))

    %{rows: [[active_users, active_conversations, largest_conversation_members]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT
          (SELECT count(*) FROM users WHERE tenant_id = $1::uuid AND status = 'active'),
          (SELECT count(*) FROM conversations WHERE tenant_id = $1::uuid AND archived_at IS NULL),
          COALESCE((
            SELECT max(member_count)
            FROM (
              SELECT count(m.id) AS member_count
              FROM conversations c
              LEFT JOIN conversation_memberships m
                ON m.tenant_id = c.tenant_id
               AND m.conversation_id = c.id
               AND m.left_at IS NULL
              WHERE c.tenant_id = $1::uuid
                AND c.archived_at IS NULL
              GROUP BY c.id
            ) active_conversation_members
          ), 0)
        """,
        [Ecto.UUID.dump!(tenant_id)]
      )

    over_limit = %{
      active_users: active_users > limits.max_active_users,
      active_conversations: active_conversations > limits.max_active_conversations,
      conversation_members: largest_conversation_members > limits.max_conversation_members
    }

    at_capacity = %{
      active_users: active_users == limits.max_active_users,
      active_conversations: active_conversations == limits.max_active_conversations,
      conversation_members: largest_conversation_members == limits.max_conversation_members
    }

    %{
      active_users: active_users,
      active_conversations: active_conversations,
      largest_conversation_members: largest_conversation_members,
      limits: limits,
      at_capacity:
        Map.put(at_capacity, :any, Enum.any?(at_capacity, fn {_key, value} -> value end)),
      over_limit: Map.put(over_limit, :any, Enum.any?(over_limit, fn {_key, value} -> value end))
    }
  end

  def limits(%TenantSettings{} = settings) do
    %{
      max_active_users: settings.max_active_users,
      max_active_conversations: settings.max_active_conversations,
      max_conversation_members: settings.max_conversation_members
    }
  end

  defp settings(tenant_id) do
    Repo.get_by(TenantSettings, tenant_id: tenant_id) || %TenantSettings{tenant_id: tenant_id}
  end

  defp ensure_capacity(current, increment, limit, reason) do
    if current + increment <= limit, do: :ok, else: {:error, reason}
  end
end
