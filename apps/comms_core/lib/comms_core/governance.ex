defmodule CommsCore.Governance do
  import CommsCore.Governance.Support,
    only: [owner_command_or_rollback: 1, transaction_result: 1, value: 2]

  alias CommsCore.Governance.{
    Authorization,
    DeletionWorkflow,
    PolicyManagement,
    Projector,
    TenantLock
  }

  alias CommsCore.{Accounts, Messaging, Repo}

  @typedoc "Scalar values allowed across this facade boundary."
  @type public_scalar ::
          atom()
          | binary()
          | boolean()
          | integer()
          | float()
          | DateTime.t()
          | NaiveDateTime.t()
          | nil

  @typedoc "Persistence-neutral structured data with scalar leaves."
  @type public_map :: %{
          optional(atom() | binary()) =>
            public_scalar() | public_map() | [public_scalar() | public_map()]
        }

  @typedoc "Named DTOs owned by this bounded context."
  @type public_contract ::
          CommsCore.Governance.DeletionExecution.t()
          | CommsCore.Governance.DeletionRequestView.t()
          | CommsCore.Governance.LegalHoldView.t()
          | CommsCore.Governance.RetentionPolicyView.t()

  @type public_value :: public_scalar() | public_map() | public_contract()
  @type public_input ::
          public_value() | [public_value()] | function() | module()
  @type public_error ::
          atom()
          | CommsCore.ValidationError.t()
          | public_map()
          | {atom(), public_scalar() | public_map()}
  @type public_response ::
          public_value()
          | [public_value()]
          | {:ok, public_value() | [public_value()]}
          | {:error, public_error()}

  @spec change_user_lifecycle_view(binary(), public_map(), public_map()) :: public_response()
  @spec claim_deletion_request(binary(), module()) :: public_response()
  @spec complete_deletion_request(binary(), public_input(), public_input(), module()) ::
          public_response()
  @spec create_deletion_request_view(public_map(), public_map()) :: public_response()
  @spec create_legal_hold_view(public_map(), public_map()) :: public_response()
  @spec create_retention_policy_view(public_map(), public_map()) :: public_response()
  @spec delete_message(binary(), public_map()) :: public_response()
  @spec enqueue_due_retention(binary(), module()) :: public_response()
  @spec list_deletion_request_views(public_map(), public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec list_legal_hold_views(public_map(), public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec list_retention_policy_views(public_map(), public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec record_deletion_failure(binary(), atom() | binary(), module()) :: public_response()
  @spec release_legal_hold_view(binary(), public_map(), public_map()) :: public_response()
  @spec transition_deletion_request_view(binary(), public_map(), public_map()) ::
          public_response()
  @spec update_retention_policy_view(binary(), public_map(), public_map()) :: public_response()

  @doc false
  defdelegate authorize_governance(subject), to: Authorization, as: :authorize

  def create_retention_policy_view(attrs, subject) do
    with {:ok, result} <- create_retention_policy(attrs, subject) do
      {:ok, %{result | policy: Projector.retention_policy(result.policy)}}
    end
  end

  def list_retention_policy_views(params, subject) do
    with {:ok, policies} <- list_retention_policies(params, subject) do
      {:ok, Enum.map(policies, &Projector.retention_policy/1)}
    end
  end

  def update_retention_policy_view(id, attrs, subject),
    do:
      update_retention_policy(id, attrs, subject)
      |> project_result(&Projector.retention_policy/1)

  def create_legal_hold_view(attrs, subject) do
    with {:ok, result} <- create_legal_hold(attrs, subject) do
      {:ok, %{result | hold: Projector.legal_hold(result.hold)}}
    end
  end

  def list_legal_hold_views(params, subject) do
    with {:ok, holds} <- list_legal_holds(params, subject) do
      {:ok, Enum.map(holds, &Projector.legal_hold/1)}
    end
  end

  def release_legal_hold_view(id, attrs, subject),
    do:
      release_legal_hold(id, attrs, subject)
      |> project_result(&Projector.legal_hold/1)

  def create_deletion_request_view(attrs, subject) do
    with {:ok, result} <- create_deletion_request(attrs, subject) do
      {:ok, %{result | request: Projector.deletion_request(result.request)}}
    end
  end

  def list_deletion_request_views(params, subject) do
    with {:ok, requests} <- list_deletion_requests(params, subject) do
      {:ok, Enum.map(requests, &Projector.deletion_request/1)}
    end
  end

  def transition_deletion_request_view(id, attrs, subject),
    do:
      transition_deletion_request(id, attrs, subject)
      |> project_result(&Projector.deletion_request/1)

  @doc """
  Coordinates an IdentityAccess user-lifecycle change with Governance policy.

  Approved and in-progress deletion requests are reduced to user identifiers
  and supplied to the IdentityAccess owner command in the same transaction.
  """
  def change_user_lifecycle_view(user_id, attrs, subject)
      when is_binary(user_id) and is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)

    with :ok <- Accounts.preflight_user_lifecycle_change(user_id, attrs, subject) do
      Repo.transaction(fn ->
        TenantLock.lock!(tenant_id)

        Accounts.apply_user_lifecycle_change(
          user_id,
          attrs,
          subject,
          DeletionWorkflow.pending_deletion_user_ids(tenant_id)
        )
        |> owner_command_or_rollback()
      end)
      |> transaction_result()
    end
  end

  def change_user_lifecycle_view(_user_id, _attrs, _subject), do: {:error, :not_found}

  def delete_message(message_id, subject) when is_binary(message_id) and is_map(subject) do
    Repo.transaction(fn ->
      case Messaging.delete_message(
             message_id,
             subject,
             &DeletionWorkflow.authorize_message_deletion/1
           ) do
        {:ok, message} -> message
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> transaction_result()
  end

  def delete_message(_message_id, _subject), do: {:error, :not_found}

  defdelegate create_retention_policy(attrs, subject), to: PolicyManagement
  defdelegate list_retention_policies(params, subject), to: PolicyManagement
  defdelegate update_retention_policy(id, attrs, subject), to: PolicyManagement
  defdelegate create_legal_hold(attrs, subject), to: PolicyManagement
  defdelegate list_legal_holds(params, subject), to: PolicyManagement
  defdelegate release_legal_hold(id, attrs, subject), to: PolicyManagement
  defdelegate enqueue_due_retention(tenant_id, caller), to: PolicyManagement

  defdelegate create_deletion_request(attrs, subject), to: DeletionWorkflow
  defdelegate list_deletion_requests(params, subject), to: DeletionWorkflow
  defdelegate transition_deletion_request(id, attrs, subject), to: DeletionWorkflow
  defdelegate claim_deletion_request(id, caller), to: DeletionWorkflow

  defdelegate complete_deletion_request(id, expected_version, worker_evidence, caller),
    to: DeletionWorkflow

  defdelegate record_deletion_failure(id, reason, caller), to: DeletionWorkflow

  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error
end
