defmodule CommsCore.Governance.PolicyManagement do
  @moduledoc false

  alias CommsCore.Governance.{LegalHolds, RetentionExecution, RetentionPolicies}
  alias CommsCore.Repo

  def create_retention_policy(attrs, subject) do
    RetentionPolicies.create_retention_policy(attrs, subject, &insert_retention_job/1)
  end

  defdelegate list_retention_policies(params, subject), to: RetentionPolicies

  def update_retention_policy(id, attrs, subject) do
    RetentionPolicies.update_retention_policy(id, attrs, subject, &insert_retention_job/1)
  end

  defdelegate create_legal_hold(attrs, subject), to: LegalHolds
  defdelegate list_legal_holds(params, subject), to: LegalHolds
  defdelegate release_legal_hold(id, attrs, subject), to: LegalHolds

  defdelegate enqueue_due_retention(tenant_id, caller), to: RetentionExecution

  defp insert_retention_job(changeset), do: Repo.insert(changeset)
end
