defmodule CommsTestSupport.Fixtures do
  alias CommsCore.Accounts
  alias CommsCore.Accounts.User
  alias CommsCore.Administration.Tenant
  alias CommsCore.Conversations.Conversation
  alias CommsCore.Repo
  alias CommsCore.Security.Password

  def account_fixture(overrides \\ %{}) do
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

    attrs =
      Map.merge(
        %{
          tenant_name: "Fixture #{suffix}",
          tenant_slug: "fixture-#{suffix}",
          display_name: "Fixture Owner",
          email: "owner-#{suffix}@example.test",
          password: "correct-horse-battery-#{suffix}",
          device_name: "Test browser",
          device_platform: "test"
        },
        overrides
      )

    {:ok, account} = Accounts.bootstrap_tenant(attrs)

    %{
      account
      | tenant: Repo.get!(Tenant, account.tenant.id),
        conversation: Repo.get!(Conversation, account.conversation.id)
    }
  end

  def user_fixture(account, overrides \\ %{}) do
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

    attrs =
      Map.merge(
        %{
          tenant_id: account.tenant.id,
          external_subject: "local:member-#{suffix}@example.test",
          display_name: "Member #{suffix}",
          email: "member-#{suffix}@example.test",
          password_hash: Password.hash("correct-horse-battery-#{suffix}"),
          role: :member,
          status: :active
        },
        overrides
      )

    {:ok, user} = %User{} |> User.changeset(attrs) |> Repo.insert()
    %{user: user}
  end

  def subject(account, overrides \\ %{}) do
    Map.merge(
      %{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        device_id: account.device.id,
        session_id: account.session.id,
        role: account.user.role,
        request_id: "test-request"
      },
      overrides
    )
  end

  def step_up(account, subject \\ nil) do
    subject = subject || subject(account)
    suffix = account.tenant.slug |> String.split("-") |> List.last()

    {:ok, _session} =
      Accounts.step_up(%{current_password: "correct-horse-battery-#{suffix}"}, subject)

    subject
  end
end
