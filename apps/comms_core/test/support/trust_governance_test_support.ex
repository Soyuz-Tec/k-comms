defmodule CommsCore.TrustGovernanceTestSupport do
  @moduledoc false

  alias CommsCore.{Accounts, Audit}

  def authenticated_subject(account, user, device_name) do
    password_suffix = user.email |> String.split(["member-", "@"], trim: true) |> hd()
    password = "correct-horse-battery-#{password_suffix}"

    {:ok, result} =
      Accounts.authenticate_view(account.tenant.slug, user.email, password, %{
        name: device_name,
        platform: "test"
      })

    {:ok, access_context} = Accounts.access_context(result.session_id)
    access_context.subject
  end

  def tenant_audit_count(tenant_id), do: Audit.count(%{tenant_id: tenant_id})
end
