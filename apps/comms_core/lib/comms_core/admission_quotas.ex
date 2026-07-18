defmodule CommsCore.AdmissionQuotas do
  @moduledoc """
  Tenant-owned admission policy and the shared tenant admission lock.

  Resource owners acquire the policy through `locked_policy/1`, observe their
  own persistence, and pass scalar counts to the policy decisions. This keeps
  the tenant-scoped PostgreSQL advisory lock shared without transferring table
  ownership to TenantAdministration.
  """

  alias CommsCore.Administration.{AdmissionPolicy, AdmissionPolicyReader}
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

  @spec locked_policy(Ecto.UUID.t()) ::
          {:ok, AdmissionPolicy.t()} | {:error, :quota_transaction_required}
  def locked_policy(tenant_id) when is_binary(tenant_id) do
    with :ok <- lock_tenant(tenant_id) do
      {:ok, AdmissionPolicyReader.read(tenant_id)}
    end
  end

  def locked_policy(_), do: {:error, :quota_transaction_required}

  @spec admission_policy(Ecto.UUID.t()) :: AdmissionPolicy.t()
  def admission_policy(tenant_id) when is_binary(tenant_id),
    do: AdmissionPolicyReader.read(tenant_id)

  @spec check_active_user_capacity(
          AdmissionPolicy.t(),
          non_neg_integer(),
          pos_integer()
        ) :: :ok | {:error, :active_user_quota_exceeded}
  def check_active_user_capacity(
        %AdmissionPolicy{} = policy,
        current_active_users,
        increment \\ 1
      )
      when is_integer(current_active_users) and current_active_users >= 0 and
             is_integer(increment) and increment > 0 do
    ensure_capacity(
      current_active_users,
      increment,
      policy.max_active_users,
      :active_user_quota_exceeded
    )
  end

  @spec check_conversation_creation(
          AdmissionPolicy.t(),
          non_neg_integer(),
          pos_integer()
        ) ::
          :ok
          | {:error, :active_conversation_quota_exceeded | :conversation_member_quota_exceeded}
  def check_conversation_creation(
        %AdmissionPolicy{} = policy,
        current_active_conversations,
        initial_member_count
      )
      when is_integer(current_active_conversations) and current_active_conversations >= 0 and
             is_integer(initial_member_count) and initial_member_count > 0 do
    with :ok <-
           ensure_capacity(
             current_active_conversations,
             1,
             policy.max_active_conversations,
             :active_conversation_quota_exceeded
           ) do
      ensure_capacity(
        0,
        initial_member_count,
        policy.max_conversation_members,
        :conversation_member_quota_exceeded
      )
    end
  end

  @spec check_conversation_member_capacity(
          AdmissionPolicy.t(),
          non_neg_integer(),
          pos_integer()
        ) :: :ok | {:error, :conversation_member_quota_exceeded}
  def check_conversation_member_capacity(
        %AdmissionPolicy{} = policy,
        current_active_members,
        increment \\ 1
      )
      when is_integer(current_active_members) and current_active_members >= 0 and
             is_integer(increment) and increment > 0 do
    ensure_capacity(
      current_active_members,
      increment,
      policy.max_conversation_members,
      :conversation_member_quota_exceeded
    )
  end

  defp ensure_capacity(current, increment, limit, reason) do
    if current + increment <= limit, do: :ok, else: {:error, reason}
  end
end
