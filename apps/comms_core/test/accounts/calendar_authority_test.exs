defmodule CommsCore.Accounts.CalendarAuthorityTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Accounts.{CalendarActorLockQuery, CalendarWorkerLockQuery, Session, User}
  alias CommsCore.Administration.Tenant
  alias CommsCore.EphemeralRoomFixtures
  alias CommsTestSupport.Fixtures

  test "calendar actor requires an owner transaction and a current step-up when requested" do
    account = Fixtures.account_fixture()
    query = actor(Fixtures.subject(account), true)
    assert {:error, :transaction_required} = Accounts.lock_calendar_actor(query)

    assert {:ok, {:error, :step_up_required}} =
             Repo.transaction(fn -> Accounts.lock_calendar_actor(query) end)

    subject = Fixtures.step_up(account)

    assert {:ok, {:ok, %{user_id: user_id, access_scope: :workspace}}} =
             Repo.transaction(fn -> Accounts.lock_calendar_actor(actor(subject, true)) end)

    assert user_id == account.user.id
  end

  test "every existing tenant role may retain workspace-human calendar authority" do
    account = Fixtures.account_fixture()

    for role <- [:member, :moderator, :admin, :security_admin, :compliance_admin, :owner] do
      Repo.update_all(from(u in User, where: u.id == ^account.user.id), set: [role: role])

      assert {:ok, {:ok, %{role: ^role}}} =
               Repo.transaction(fn ->
                 Accounts.lock_calendar_actor(actor(Fixtures.subject(account), false))
               end)
    end
  end

  test "limited human authority remains valid for conversation access and cannot export calendars" do
    account = Fixtures.account_fixture()

    Repo.update_all(from(u in User, where: u.id == ^account.user.id),
      set: [access_scope: :conversation_only]
    )

    subject = Fixtures.subject(account)

    assert {:ok, %{account_type: :human, access_scope: :conversation_only}} =
             Accounts.access_grant(subject)

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn -> Accounts.lock_calendar_actor(actor(subject, false)) end)

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn -> Accounts.lock_calendar_worker(worker(account, :export)) end)

    assert {:ok, {:ok, %{purpose: :cleanup}}} =
             Repo.transaction(fn -> Accounts.lock_calendar_worker(worker(account, :cleanup)) end)
  end

  test "an actual admitted Guest keeps room eligibility and cannot obtain calendar authority" do
    account = Fixtures.account_fixture()
    previous_enabled = Application.get_env(:comms_core, :instant_rooms_enabled)
    previous_slug = Application.get_env(:comms_core, :instant_room_tenant_slug)

    on_exit(fn ->
      restore(:instant_rooms_enabled, previous_enabled)
      restore(:instant_room_tenant_slug, previous_slug)
    end)

    attrs =
      EphemeralRoomFixtures.guest_create_attrs(account.tenant.id, EphemeralRoomFixtures.secret())

    assert {:ok, room} = Conversations.create_ephemeral_room(attrs, :guest)
    subject = EphemeralRoomFixtures.guest_subject(room)
    assert {:ok, %{account_type: :guest}} = Accounts.access_grant(subject)

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn -> Accounts.lock_calendar_actor(actor(subject, false)) end)

    guest_worker = %CalendarWorkerLockQuery{
      tenant_id: subject.tenant_id,
      user_id: subject.user_id,
      purpose: :cleanup,
      deadline_ms: deadline()
    }

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn -> Accounts.lock_calendar_worker(guest_worker) end)

    assert {:ok, %{account_type: :guest}} = Accounts.access_grant(subject)
  end

  test "offline authority uses the exact active human and does not invent a live session" do
    account = Fixtures.account_fixture()

    Repo.update_all(from(s in Session, where: s.user_id == ^account.user.id),
      set: [revoked_at: DateTime.utc_now()]
    )

    assert {:error, :forbidden} = Accounts.access_grant(Fixtures.subject(account))

    assert {:ok, {:ok, %{purpose: :export, user_id: id}}} =
             Repo.transaction(fn ->
               Accounts.lock_calendar_worker(worker(account, :export))
             end)

    assert id == account.user.id
  end

  test "suspended tenant and identity permit exact delete-only cleanup but deny new export" do
    account = Fixtures.account_fixture()
    Repo.update_all(from(u in User, where: u.id == ^account.user.id), set: [status: :suspended])

    Repo.update_all(from(t in Tenant, where: t.id == ^account.tenant.id),
      set: [status: :suspended]
    )

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn -> Accounts.lock_calendar_worker(worker(account, :export)) end)

    assert {:ok, {:ok, %{purpose: :cleanup}}} =
             Repo.transaction(fn -> Accounts.lock_calendar_worker(worker(account, :cleanup)) end)
  end

  test "a foreign identity UUID cannot substitute for the retained connection owner" do
    account = Fixtures.account_fixture()
    other = Fixtures.account_fixture()

    query = %CalendarWorkerLockQuery{
      tenant_id: account.tenant.id,
      user_id: other.user.id,
      purpose: :cleanup,
      deadline_ms: deadline()
    }

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn -> Accounts.lock_calendar_worker(query) end)
  end

  defp actor(subject, step_up),
    do: %CalendarActorLockQuery{
      subject: subject,
      require_step_up?: step_up,
      deadline_ms: deadline()
    }

  defp worker(account, purpose),
    do: %CalendarWorkerLockQuery{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      purpose: purpose,
      deadline_ms: deadline()
    }

  defp deadline, do: System.monotonic_time(:millisecond) + 15_000
  defp restore(key, nil), do: Application.delete_env(:comms_core, key)
  defp restore(key, value), do: Application.put_env(:comms_core, key, value)
end
