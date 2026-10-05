defmodule CommsCore.PhoneProvisioningTest.Adapter do
  import Kernel, except: [inspect: 1]
  @behaviour CommsCore.Telephony.ProvisioningPort.Contract
  def status(_tenant),
    do: %{
      enabled: true,
      ready: true,
      reason: nil,
      number_purchase: false,
      trunk_credentials_edit: false
    }

  def inspect(_request), do: {:error, :provider_unavailable}
  def apply(_request), do: {:error, :provider_outcome_unknown}
end

defmodule CommsCore.PhoneProvisioningTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsCore.{Repo, Telephony}
  alias CommsCore.Telephony.{Number, ProvisioningCommand}
  alias CommsTestSupport.Fixtures
  alias CommsCore.PhoneProvisioningTest.Adapter

  setup do
    keys = [:telephony_provisioning_enabled, :telephony_provisioning_adapter]
    previous = Map.new(keys, &{&1, Application.get_env(:comms_core, &1)})
    Application.put_env(:comms_core, :telephony_provisioning_enabled, true)
    Application.put_env(:comms_core, :telephony_provisioning_adapter, Adapter)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value == nil,
          do: Application.delete_env(:comms_core, key),
          else: Application.put_env(:comms_core, key, value)
      end)
    end)

    account = Fixtures.account_fixture()
    {:ok, account: account, subject: Fixtures.step_up(account)}
  end

  test "management stays off by default and stale role claims grant no provider access", %{
    account: account,
    subject: subject
  } do
    Application.put_env(:comms_core, :telephony_provisioning_enabled, false)

    assert {:ok, %{provider: %{enabled: false, ready: false}}} =
             Telephony.phone_provisioning_state(subject)

    assert {:error, :telephony_provisioning_disabled} =
             Telephony.inspect_phone_provisioning(input(account), subject)

    assert Repo.aggregate(ProvisioningCommand, :count) == 0
    account.user |> Ecto.Changeset.change(role: :member) |> Repo.update!()

    assert {:error, :forbidden} =
             Telephony.phone_provisioning_state(Map.put(subject, :role, :owner))
  end

  test "current persisted step-up and workspace human assignment precede command storage", %{
    account: account,
    subject: subject
  } do
    other = Fixtures.account_fixture()

    assert {:error, :forbidden} =
             Telephony.inspect_phone_provisioning(
               Map.put(input(account), :user_id, other.user.id),
               subject
             )

    account.user |> Ecto.Changeset.change(access_scope: :conversation_only) |> Repo.update!()
    assert {:error, :forbidden} = Telephony.inspect_phone_provisioning(input(account), subject)
    assert Repo.aggregate(ProvisioningCommand, :count) == 0
  end

  test "missing current step-up fails before setup details are accepted" do
    account = Fixtures.account_fixture()

    assert {:error, :step_up_required} =
             Telephony.inspect_phone_provisioning(input(account), Fixtures.subject(account))

    assert Repo.aggregate(ProvisioningCommand, :count) == 0
  end

  test "typed IO authority admits only the configured complete adapter while management is enabled",
       %{
         account: account,
         subject: subject
       } do
    alias CommsCore.Telephony.ProvisioningAuthorityPort
    {:ok, {_view, lease}} = Telephony.inspect_phone_provisioning(input(account), subject)
    assert {:error, :forbidden} = ProvisioningAuthorityPort.authorize_io(lease, :read, __MODULE__)
    assert :ok = ProvisioningAuthorityPort.authorize_io(lease, :read, Adapter)
    refute Repo.get!(ProvisioningCommand, lease.command_id).effect_consumed

    Application.put_env(:comms_core, :telephony_provisioning_enabled, false)
    assert {:error, :forbidden} = ProvisioningAuthorityPort.authorize_io(lease, :read, Adapter)
    Application.put_env(:comms_core, :telephony_provisioning_enabled, true)
    Application.put_env(:comms_core, :telephony_provisioning_adapter, __MODULE__)
    assert {:error, :forbidden} = ProvisioningAuthorityPort.authorize_io(lease, :read, __MODULE__)
    refute Repo.get!(ProvisioningCommand, lease.command_id).effect_consumed
  end

  test "inspection idempotency binds the exact assignment and never creates another lease", %{
    account: account,
    subject: subject
  } do
    attrs = input(account)
    assert {:ok, {first, request}} = Telephony.inspect_phone_provisioning(attrs, subject)
    assert request != nil
    assert {:ok, {replay, nil}} = Telephony.inspect_phone_provisioning(attrs, subject)
    assert replay.id == first.id

    assert {:error, :idempotency_conflict} =
             Telephony.inspect_phone_provisioning(Map.put(attrs, :extension, "102"), subject)

    assert Repo.aggregate(ProvisioningCommand, :count) == 1
  end

  test "provider secret fields and lease authority never enter saved evidence or client views", %{
    account: account,
    subject: subject
  } do
    {:ok, {_view, lease}} = Telephony.inspect_phone_provisioning(input(account), subject)
    evidence = Map.put(snapshot(lease), :auth_password, "synthetic-provider-secret")
    assert {:ok, view} = Telephony.complete_phone_provisioning(lease, {:ok, evidence}, subject)
    command = Repo.get!(ProvisioningCommand, view.id)
    refute Map.has_key?(command.snapshot, "auth_password")
    refute Map.has_key?(view, :lease_token)
    refute Map.has_key?(view, :actor_session_id)
    refute Jason.encode!(view) =~ "synthetic-provider-secret"
    refute inspect(lease) =~ lease.lease_token
  end

  test "row CAS and assignment generation fence an apply before provider IO", %{
    account: account,
    subject: subject
  } do
    verified = verified(account, subject)

    assert {:error, :stale_version} =
             Telephony.apply_phone_provisioning(
               verified.id,
               %{version: verified.version - 1, reason: "Stale view"},
               subject
             )

    Repo.insert!(%Number{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      phone_number: "+14155550124",
      extension: "102",
      inbound_trunk_id: "ST_other_in",
      outbound_trunk_id: "ST_other_out"
    })

    assert {:error, :stale_version} =
             Telephony.apply_phone_provisioning(
               verified.id,
               %{version: verified.version, reason: "Apply inspected setup"},
               subject
             )

    refute Repo.get!(ProvisioningCommand, verified.id).effect_consumed
  end

  test "a ready projection without an actual provider rule cannot save an assignment", %{
    account: account,
    subject: subject
  } do
    verified = verified(account, subject)

    {:ok, {_view, lease}} =
      Telephony.apply_phone_provisioning(
        verified.id,
        %{version: verified.version, reason: "Apply inspected setup"},
        subject
      )

    malformed =
      snapshot(lease) |> Map.put(:dispatch_ready, true) |> Map.put(:dispatch_rule_id, nil)

    assert {:ok, %{status: "failed"}} =
             Telephony.complete_phone_provisioning(lease, {:ok, malformed}, subject)

    assert Repo.aggregate(Number, :count) == 0
  end

  test "typed lease cannot substitute another DID, trunk or operation under the same token", %{
    account: account,
    subject: subject
  } do
    verified = verified(account, subject)

    {:ok, {_view, lease}} =
      Telephony.apply_phone_provisioning(
        verified.id,
        %{version: verified.version, reason: "Apply setup"},
        subject
      )

    for changed <- [
          %{lease | phone_number: "+14155550124"},
          %{lease | inbound_trunk_id: "ST_substituted"},
          %{lease | mode: :reconcile}
        ] do
      assert {:error, :telephony_lease_expired} =
               Telephony.authorize_phone_provisioning_io(changed, :effect, Adapter)
    end

    refute Repo.get!(ProvisioningCommand, lease.command_id).effect_consumed
    assert :ok = Telephony.authorize_phone_provisioning_io(lease, :effect, Adapter)
  end

  test "effect capability is consumed once and uncertain creation blocks new effects", %{
    account: account,
    subject: subject
  } do
    verified = verified(account, subject)

    {:ok, {_view, lease}} =
      Telephony.apply_phone_provisioning(
        verified.id,
        %{version: verified.version, reason: "Apply setup"},
        subject
      )

    assert :ok = Telephony.authorize_phone_provisioning_io(lease, :effect, Adapter)

    assert {:error, :telephony_outcome_unknown} =
             Telephony.authorize_phone_provisioning_io(lease, :effect, Adapter)

    assert {:ok, %{status: "unknown"}} =
             Telephony.complete_phone_provisioning(
               lease,
               {:error, :provider_outcome_unknown},
               subject
             )

    assert {:error, :telephony_outcome_unknown} =
             Telephony.inspect_phone_provisioning(input(account), subject)

    assert Telephony.rollback_phone_provisioning_hazard_count() == 1
    assert Repo.aggregate(Number, :count) == 0
  end

  test "uncertain outcome reconciles read-only under a fresh current owner and assigns once", %{
    account: account,
    subject: subject
  } do
    verified = verified(account, subject)

    {:ok, {_view, lease}} =
      Telephony.apply_phone_provisioning(
        verified.id,
        %{version: verified.version, reason: "Apply setup"},
        subject
      )

    :ok = Telephony.authorize_phone_provisioning_io(lease, :effect, Adapter)

    {:ok, unknown} =
      Telephony.complete_phone_provisioning(lease, {:error, :provider_outcome_unknown}, subject)

    {:ok, {_view, read}} =
      Telephony.reconcile_phone_provisioning(
        unknown.id,
        %{version: unknown.version, reason: "Observe original create"},
        subject
      )

    assert {:error, :telephony_outcome_unknown} =
             Telephony.authorize_phone_provisioning_io(read, :effect, Adapter)

    assert :ok = Telephony.authorize_phone_provisioning_io(read, :read, Adapter)

    assert {:ok, %{status: "applied"}} =
             Telephony.complete_phone_provisioning(
               read,
               {:ok, snapshot(read, "SD_original")},
               subject
             )

    assert %{phone_number: "+14155550123", lock_version: 1} =
             Repo.get_by!(Number, tenant_id: account.tenant.id)

    assert {:error, :stale_version} =
             Telephony.reconcile_phone_provisioning(
               unknown.id,
               %{version: unknown.version, reason: "Repeat stale reconcile"},
               subject
             )
  end

  test "an expired unused effect lease proves no create and cannot authorize late IO", %{
    account: account,
    subject: subject
  } do
    verified = verified(account, subject)

    {:ok, {_view, lease}} =
      Telephony.apply_phone_provisioning(
        verified.id,
        %{version: verified.version, reason: "Apply setup"},
        subject
      )

    Repo.get!(ProvisioningCommand, lease.command_id)
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:error, :telephony_lease_expired} =
             Telephony.authorize_phone_provisioning_io(lease, :effect, Adapter)

    refute Repo.get!(ProvisioningCommand, lease.command_id).effect_consumed

    assert {:ok, {_next, _request}} =
             Telephony.inspect_phone_provisioning(input(account), subject)
  end

  test "role or scope withdrawal after inspection prevents provider effect", %{
    account: account,
    subject: subject
  } do
    verified = verified(account, subject)

    {:ok, {_view, lease}} =
      Telephony.apply_phone_provisioning(
        verified.id,
        %{version: verified.version, reason: "Apply setup"},
        subject
      )

    account.user |> Ecto.Changeset.change(role: :member) |> Repo.update!()

    assert {:error, :forbidden} =
             Telephony.authorize_phone_provisioning_io(lease, :effect, Adapter)

    refute Repo.get!(ProvisioningCommand, lease.command_id).effect_consumed
    other = Fixtures.account_fixture()

    assert {:error, :not_found} =
             Telephony.apply_phone_provisioning(
               verified.id,
               %{version: 3, reason: "Another tenant"},
               Fixtures.step_up(other)
             )
  end

  defp verified(account, subject) do
    {:ok, {_view, lease}} = Telephony.inspect_phone_provisioning(input(account), subject)
    {:ok, view} = Telephony.complete_phone_provisioning(lease, {:ok, snapshot(lease)}, subject)
    view
  end

  defp input(account),
    do: %{
      user_id: account.user.id,
      phone_number: "+14155550123",
      extension: "101",
      inbound_trunk_id: "ST_in",
      outbound_trunk_id: "ST_out",
      assignment_version: 0,
      idempotency_key: Ecto.UUID.generate(),
      reason: "Synthetic provider setup"
    }

  defp snapshot(lease, rule_id \\ nil),
    do: %{
      phone_number: lease.phone_number,
      inbound_trunk_id: lease.inbound_trunk_id,
      outbound_trunk_id: lease.outbound_trunk_id,
      dispatch_ready: rule_id != nil,
      dispatch_rule_id: rule_id,
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
end
