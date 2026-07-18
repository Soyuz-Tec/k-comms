defmodule CommsCore.AuditTest do
  use CommsCore.DataCase, async: true

  alias CommsCore.{Accounts, Audit}
  alias CommsCore.Audit.{Actor, Error, Event}
  alias CommsCore.Repo
  alias CommsTestSupport.Fixtures

  test "record validates, persists, and returns a persistence-neutral event" do
    account = Fixtures.account_fixture()

    assert {:ok, %Event{} = event} =
             Audit.record(%{
               tenant_id: account.tenant.id,
               actor_user_id: account.user.id,
               action: "audit.facade_test",
               resource_type: "tenant",
               resource_id: account.tenant.id,
               metadata: %{source: "test"},
               request_id: "request:audit-test"
             })

    refute Map.has_key?(event, :__meta__)

    assert %Event{id: id, action: "audit.facade_test"} =
             Audit.get_by!(%{tenant_id: account.tenant.id, id: event.id})

    assert id == event.id
  end

  test "record translates internal changeset failures into a stable public error" do
    assert {:error, %Error{reason: :invalid_audit_event} = error} = Audit.record(%{})
    assert error.errors[:tenant_id] == ["can't be blank"]
    refute Map.has_key?(error, :data)
  end

  test "authorization denials are recorded through the public facade and retain the denial" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, %Actor{} = actor} = Accounts.authorization_audit_actor(subject)

    assert {:error, :step_up_required} =
             Audit.authorization_denied(:manage_integrations, actor, :step_up_required)

    assert %Event{} =
             event =
             Audit.get_by!(%{
               tenant_id: account.tenant.id,
               actor_user_id: account.user.id,
               action: "authorization.denied"
             })

    assert event.resource_type == "permission"
    assert event.resource_id == account.tenant.id
    assert event.metadata["permission"] == "manage_integrations"
    assert event.metadata["reason"] == "step_up_required"

    assert {:error, :forbidden} =
             Accounts.audit_authorization_denial(
               :manage_integrations,
               %{tenant_id: "invalid", user_id: "invalid"},
               :forbidden
             )

    assert 1 ==
             Audit.count(%{
               tenant_id: account.tenant.id,
               actor_user_id: account.user.id,
               action: "authorization.denied"
             })
  end

  test "authorization audit actor rejects cross-tenant and unknown user claims" do
    first = Fixtures.account_fixture()
    second = Fixtures.account_fixture()

    for subject <- [
          %{
            tenant_id: first.tenant.id,
            user_id: second.user.id,
            request_id: "request:cross-tenant"
          },
          %{
            tenant_id: first.tenant.id,
            user_id: Ecto.UUID.generate(),
            request_id: "request:unknown-user"
          }
        ] do
      assert {:error, :unknown_authorization_actor} =
               Accounts.authorization_audit_actor(subject)

      assert {:error, :forbidden} =
               Accounts.audit_authorization_denial(
                 :manage_integrations,
                 subject,
                 :forbidden
               )
    end

    assert 0 ==
             Audit.count(%{
               tenant_id: first.tenant.id,
               action: "authorization.denied"
             })
  end

  test "append participates in the caller transaction without exposing the schema" do
    account = Fixtures.account_fixture()

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:business_change, fn _repo, _changes -> {:ok, :done} end)
      |> Audit.append(%{
        tenant_id: account.tenant.id,
        actor_user_id: account.user.id,
        action: "audit.append_test",
        resource_type: "tenant",
        resource_id: account.tenant.id,
        metadata: %{}
      })

    assert {:ok, %{business_change: :done, audit: %Event{action: "audit.append_test"}}} =
             Repo.transaction(multi)
  end

  test "invalid append fails the transaction with a public error" do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:business_change, fn _repo, _changes -> {:ok, :done} end)
      |> Audit.append(%{action: "audit.invalid", metadata: %{}})

    assert {:error, :audit, %Error{reason: :invalid_audit_event}, %{business_change: :done}} =
             Repo.transaction(multi)
  end

  test "public query APIs require a tenant boundary" do
    assert_raise ArgumentError, "Audit queries require tenant_id", fn -> Audit.list(%{}) end
    assert_raise ArgumentError, "Audit queries require tenant_id", fn -> Audit.count(%{}) end
    assert_raise ArgumentError, "Audit queries require tenant_id", fn -> Audit.get_by(%{}) end
  end
end
