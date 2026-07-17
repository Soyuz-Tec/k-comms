defmodule CommsCore.AuditTest do
  use CommsCore.DataCase, async: true

  alias CommsCore.Audit
  alias CommsCore.Audit.{Error, Event}
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
