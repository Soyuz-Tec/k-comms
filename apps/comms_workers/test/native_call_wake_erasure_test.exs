defmodule CommsWorkers.NativeCallWakeErasureTest.Provider do
  @behaviour CommsCore.Notifications.NativePushProviderPort.Contract
  def status, do: %{status: :available, channels: ["apns_voip"]}
  def deliver(_, _), do: raise("Governance erasure must never send native push")
end

defmodule CommsWorkers.NativeCallWakeErasureTest.OrderAdapter do
  @behaviour CommsCore.Accounts.NotificationPort
  import Ecto.Query
  alias CommsCore.{Notifications, Repo}
  alias CommsCore.Accounts.{Device, NotificationCommand, Session}
  def execute(%NotificationCommand{operation: :user_erased} = command) do
    # The actual final contribution is still inside the owner transaction and
    # retains identity parents; generic cascades cannot prove native erasure.
    true = Repo.in_transaction?()
    sessions = Repo.aggregate(from(s in Session, where: s.tenant_id == ^command.tenant_id and s.user_id == ^command.user_id), :count)
    devices = Repo.aggregate(from(d in Device, where: d.tenant_id == ^command.tenant_id and d.user_id == ^command.user_id), :count)
    send(self(), {:native_erasure_parent_order, sessions, devices})
    Notifications.execute(command)
  end
  def execute(command), do: Notifications.execute(command)
end

defmodule CommsWorkers.NativeCallWakeErasureTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.{Accounts, Conversations, Governance, Messaging, Notifications, Repo}
  alias CommsCore.Accounts.{Device, Session, User}
  alias CommsCore.Notifications.{NativeCallWake, NativePushRegistration}
  alias CommsTestSupport.Fixtures
  @moduletag :integration
  @moduletag :governance

  setup do
    config = [native_push_enabled: true, native_push_encryption_key: :crypto.strong_rand_bytes(32), native_push_encryption_keys: nil,
      native_push_provider_adapter: __MODULE__.Provider, identity_notification_adapter: __MODULE__.OrderAdapter,
      native_push_platforms: [%{platform: "ios", channel: "apns_voip", application_id: "com.synthetic.native", environment: "sandbox", device_qualified: true}]]
    previous = Map.new(config, fn {key, _} -> {key, Application.fetch_env(:comms_core, key)} end)
    Enum.each(config, fn {key, value} -> Application.put_env(:comms_core, key, value) end)
    on_exit(fn -> Enum.each(previous, fn
      {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
      {key, :error} -> Application.delete_env(:comms_core, key)
    end) end)
    owner = Fixtures.account_fixture(); administrator = Fixtures.step_up(owner)
    target = member(owner); assert {:ok, _} = Conversations.add_member(owner.conversation.id, target.user_id, :member, administrator)
    row = registration(target, "a")
    wake = intent(row)
    %{owner: owner, administrator: administrator, target: target, row: row, wake: wake}
  end

  test "registered DeletionWorker erases exact native ownership before identity cleanup and preserves unrelated identities", c do
    same_tenant = registration(Fixtures.subject(c.owner), "b")
    other = Fixtures.account_fixture(); foreign = registration(Fixtures.subject(other), "c")
    # A BEFORE DELETE trigger executes before FK cascades. The actual worker
    # must explicitly erase owned wakes before attempting registration removal.
    Repo.query!("""
    CREATE FUNCTION native_wake_erasure_order_fixture() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM native_call_wakes WHERE registration_id = OLD.id) THEN
        RAISE EXCEPTION 'native owner must erase wakes before registration';
      END IF;
      RETURN OLD;
    END $$
    """)
    Repo.query!("""
    CREATE TRIGGER native_wake_erasure_order_fixture BEFORE DELETE ON native_push_registrations
    FOR EACH ROW EXECUTE FUNCTION native_wake_erasure_order_fixture()
    """)
    request = approved_request(c)
    assert :ok = CommsWorkers.DeletionWorker.perform(%Oban.Job{args: %{"deletion_request_id" => request.id}})
    assert_received {:native_erasure_parent_order, session_count, device_count}
    assert session_count > 0 && device_count > 0
    assert Repo.get!(User, c.target.user_id).status == :deleted
    assert Repo.get!(Session, c.target.session_id).revoked_at
    assert Repo.get!(Device, c.target.device_id).revoked_at
    assert is_nil(Repo.get(NativePushRegistration, c.row.id)); assert is_nil(Repo.get(NativeCallWake, c.wake.id))
    assert Repo.get!(NativePushRegistration, same_tenant.id).status == "active"
    assert Repo.get!(NativePushRegistration, foreign.id).status == "active"
    assert Repo.get!(User, c.owner.user.id).status == :active
    assert Repo.get!(User, other.user.id).status == :active
  end

  test "a legal hold refuses registered deletion without wiping native provenance or held message content", c do
    assert {:ok, message} = Messaging.accept_message(%{tenant_id: c.owner.tenant.id, conversation_id: c.owner.conversation.id,
      sender_user_id: c.target.user_id, sender_device_id: c.target.device_id, client_message_id: Ecto.UUID.generate(), body: "Synthetic held evidence"}, c.target)
    request = approved_request(c)
    assert {:ok, _} = Governance.create_legal_hold(%{name: "Native owner evidence hold", reason: "Preserve exact target content",
      scope_type: "user", subject_user_id: c.target.user_id}, c.administrator)
    assert {:snooze, 300} = CommsWorkers.DeletionWorker.perform(%Oban.Job{args: %{"deletion_request_id" => request.id}})
    refute_received {:native_erasure_parent_order, _, _}
    assert Repo.get!(NativePushRegistration, c.row.id).status == "active"
    assert Repo.get!(NativeCallWake, c.wake.id).status == "pending"
    assert Repo.get!(User, c.target.user_id).status == :active
    assert is_nil(Repo.get!(Session, c.target.session_id).revoked_at)
    assert Repo.get!(CommsCore.Messaging.Message, message.id).body == "Synthetic held evidence"
  end

  defp member(account) do
    member = Fixtures.user_fixture(account).user
    [local, _] = String.split(member.email, "@", parts: 2)
    suffix = String.replace_prefix(local, "member-", "")
    {:ok, result} = Accounts.authenticate_view(account.tenant.slug, member.email, "correct-horse-battery-#{suffix}", %{name: "Synthetic native", platform: "ios"})
    {:ok, context} = Accounts.access_context(result.session_id)
    context.subject
  end
  defp registration(subject, character) do
    {:ok, %{registration: view}} = Notifications.register_native_push(%{platform: "ios", channel: "apns_voip", application_id: "com.synthetic.native", environment: "sandbox",
      token: String.duplicate(character, 64), installation_id: Ecto.UUID.generate(), expected_version: 0}, subject)
    Repo.get!(NativePushRegistration, view.id)
  end
  defp intent(row) do
    Repo.insert!(NativeCallWake.changeset(%NativeCallWake{}, %{tenant_id: row.tenant_id, user_id: row.user_id, device_id: row.device_id,
      session_id: row.session_id, registration_id: row.id, registration_version: row.version, user_version: row.user_version,
      owner: "conversation", call_id: Ecto.UUID.generate(), conversation_id: Ecto.UUID.generate(), source_event_id: Ecto.UUID.generate(), expires_at: DateTime.add(DateTime.utc_now(), 25, :second), status: "pending"}))
  end
  defp approved_request(c) do
    {:ok, %{request: request}} = Governance.create_deletion_request(%{target_type: "user", subject_user_id: c.target.user_id, reason: "Erase exact synthetic native owner"}, c.administrator)
    {:ok, approved} = Governance.transition_deletion_request(request.id, %{version: request.lock_version, status: "approved", transition_reason: "Synthetic ownership verified"}, c.administrator)
    approved
  end
end
