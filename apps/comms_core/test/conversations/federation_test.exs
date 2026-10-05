defmodule CommsCore.Conversations.FederationTest.Provider do
  @behaviour CommsCore.Conversations.Federation.ProviderPort
  alias CommsCore.Conversations.Federation.ProviderReceipt

  def perform(request) do
    send(self(), {:federation_effect, request.operation, request.transaction_id})

    case request.operation do
      :send ->
        {:ok,
         %ProviderReceipt{operation: :send, event_id: "$synthetic-" <> request.transaction_id}}

      :create ->
        send(self(), {:federation_create_request, request})
        {:ok, %ProviderReceipt{operation: :create, room_id: "!synthetic:example.org"}}

      :redact ->
        send(self(), {:federation_redaction_request, request})

        case Process.get(:federation_redaction_outcome, :observed) do
          :rollback -> CommsCore.Repo.rollback(:synthetic_post_effect_failure)
          :unconfirmed -> {:error, :federation_redaction_unconfirmed}
          :observed -> {:ok, %ProviderReceipt{operation: :redact, local_redaction_observed: true}}
        end

      :leave ->
        {:ok, %ProviderReceipt{operation: :leave, local_absence_observed: true}}

      :close ->
        {:ok, %ProviderReceipt{operation: :close, local_leave_observed: true}}

      _ ->
        {:error, :federation_send_outcome_unconfirmed}
    end
  end
end

defmodule CommsCore.Conversations.FederationTest do
  use CommsCore.DataCase, async: false
  import Ecto.Query
  alias CommsCore.{Accounts, Conversations, Governance, Repo, RuntimePorts}
  alias CommsCore.Conversations.Federation.{Command, Participant, Room, SecretBox, Trust}
  alias CommsTestSupport.Fixtures
  @moduletag :integration
  setup do
    previous =
      Map.new(
        [:federation_enabled, :federation_envelope_key, :federation_provider_adapter],
        &{&1, Application.get_env(:comms_core, &1)}
      )

    Application.put_env(:comms_core, :federation_enabled, true)
    Application.put_env(:comms_core, :federation_envelope_key, :crypto.strong_rand_bytes(32))

    Application.put_env(
      :comms_core,
      :federation_provider_adapter,
      CommsCore.Conversations.FederationTest.Provider
    )

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:comms_core, key),
          else: Application.put_env(:comms_core, key, value)
      end)
    end)

    account = Fixtures.account_fixture()
    room = room_fixture(account)
    %{account: account, room: room, subject: Fixtures.subject(account)}
  end

  test "commands require actual current proof, consent, CAS and actor-bound idempotency", %{
    account: account,
    room: room,
    subject: subject
  } do
    input = %{
      version: room.lock_version,
      body: "synthetic private text",
      idempotency_key: Ecto.UUID.generate()
    }

    assert {:ok, queued} =
             Conversations.send_federation_message(account.conversation.id, input, subject)

    assert {:ok, replayed} =
             Conversations.send_federation_message(account.conversation.id, input, subject)

    assert queued.id == replayed.id

    assert {:error, :federation_idempotency_conflict} =
             Conversations.send_federation_message(
               account.conversation.id,
               %{input | body: "different"},
               subject
             )

    assert {:error, :stale_version} =
             Conversations.send_federation_message(
               account.conversation.id,
               %{input | version: 99},
               subject
             )

    assert {:error, :forbidden} =
             Conversations.deliver_federation_command(queued.id, __MODULE__, :recovery_only)

    worker = RuntimePorts.job_worker!(:federation_command)

    assert {:ok, :ok} =
             Conversations.deliver_federation_command(queued.id, worker, :recovery_only)

    assert_received {:federation_effect, :send, id}
    assert id == queued.id
    raw = Repo.get!(Command, queued.id)
    assert raw.status == "done" and is_nil(raw.payload_box)
  end

  test "ordinary session logout preserves consent but denies its queued effect", %{
    account: account,
    room: room,
    subject: subject
  } do
    assert {:ok, queued} =
             Conversations.send_federation_message(
               account.conversation.id,
               %{
                 version: room.lock_version,
                 body: "synthetic",
                 idempotency_key: Ecto.UUID.generate()
               },
               subject
             )

    assert :ok = Accounts.revoke_session(account.session.id, account.user.id)
    participant = Repo.get_by!(Participant, room_id: room.id, user_id: account.user.id)
    assert participant.consent_status == "accepted" and is_nil(participant.withdrawn_at)

    assert {:error, :forbidden} =
             Conversations.deliver_federation_command(
               queued.id,
               RuntimePorts.job_worker!(:federation_command),
               :recovery_only
             )

    refute_received {:federation_effect, _, _}
  end

  test "withdrawal queues owned cleanup and cannot restore old consent", %{
    account: account,
    room: room,
    subject: subject
  } do
    assert {:ok, updated} =
             Conversations.federation_consent(
               account.conversation.id,
               %{version: room.lock_version, accept: false},
               subject
             )

    assert updated.consent == "withdrawn" and updated.remote_cleanup_state == "pending"

    assert {:error, :federation_consent_required} =
             Conversations.send_federation_message(
               account.conversation.id,
               %{
                 version: updated.version,
                 body: "after withdrawal",
                 idempotency_key: Ecto.UUID.generate()
               },
               subject
             )

    assert {:error, :withdrawn_consent_requires_new_room} =
             Conversations.federation_consent(
               account.conversation.id,
               %{version: updated.version, accept: true, plaintext_disclosure_accepted: true},
               subject
             )

    leaves = Repo.all(from(c in Command, where: c.room_id == ^room.id and c.kind == "leave"))
    assert length(leaves) == 1

    assert {:ok, :ok} =
             Conversations.deliver_federation_command(
               hd(leaves).id,
               RuntimePorts.job_worker!(:federation_command),
               :recovery_only
             )

    assert {:ok, true} =
             Conversations.federation_erasure_pending?(account.tenant.id, :user, account.user.id)
  end

  test "foreign tenant subjects cannot observe or command an attached room", %{
    account: account,
    room: room
  } do
    foreign = Fixtures.account_fixture()

    assert {:error, :forbidden} =
             Conversations.federation_room(account.conversation.id, Fixtures.subject(foreign))

    assert {:error, :not_found} =
             Conversations.send_federation_message(
               account.conversation.id,
               %{
                 version: room.lock_version,
                 body: "foreign",
                 idempotency_key: Ecto.UUID.generate()
               },
               Fixtures.subject(foreign)
             )

    refute_received {:federation_effect, _, _}
  end

  test "administration changes use persisted recent step-up and disabling cannot resume a room",
       %{account: account, room: room, subject: subject} do
    trust = Repo.get!(Trust, room.trust_id)

    attrs = %{
      domain: trust.domain,
      residency: trust.residency,
      cross_border_reason: "Reviewed synthetic processing",
      enabled: false,
      version: trust.lock_version
    }

    assert {:error, :step_up_required} = Conversations.put_federation_trust(attrs, subject)
    verified = Fixtures.step_up(account)
    assert {:ok, disabled} = Conversations.put_federation_trust(attrs, verified)
    assert Repo.get!(Room, room.id).status == "fenced"

    assert {:ok, _} =
             Conversations.put_federation_trust(
               %{attrs | enabled: true, version: disabled.version},
               verified
             )

    assert Repo.get!(Room, room.id).status == "fenced"
  end

  test "user-held local fence is transactional and never performs a provider effect", %{
    account: account,
    room: room
  } do
    assert {:error, :transaction_required} =
             Conversations.fence_federation_user(account.tenant.id, account.user.id)

    assert {:ok, {:ok, :fenced}} =
             Repo.transaction(fn ->
               Conversations.fence_federation_user(account.tenant.id, account.user.id)
             end)

    assert Repo.get_by!(Participant, room_id: room.id, user_id: account.user.id).consent_status ==
             "withdrawn"

    refute_received {:federation_effect, _, _}
  end

  test "unknown create cleanup recovers the owned alias without inviting or restoring active sync",
       %{
         account: account,
         room: room,
         subject: subject
       } do
    room |> Room.changeset(%{status: "creating", provider_room_box: nil}) |> Repo.update!()

    assert {:ok, _} =
             Conversations.federation_consent(
               account.conversation.id,
               %{version: room.lock_version, accept: false},
               subject
             )

    recovery = Repo.get_by!(Command, room_id: room.id, kind: "recover_room")
    leave = Repo.get_by!(Command, room_id: room.id, kind: "leave")
    worker = RuntimePorts.job_worker!(:federation_command)

    assert {:error, :federation_cleanup_room_pending} =
             Conversations.deliver_federation_command(leave.id, worker, :recovery_only)

    refute_received {:federation_effect, _, _}

    assert {:ok, :ok} =
             Conversations.deliver_federation_command(recovery.id, worker, :recovery_only)

    assert_received {:federation_create_request, request}
    assert request.body == "recovery_only" and request.alias_localpart == room.alias_localpart
    assert Repo.get!(Room, room.id).status == "creating"

    refute Repo.exists?(
             from(c in Command, where: c.room_id == ^room.id and c.kind == "invite_local")
           )

    assert Repo.get_by!(Participant, room_id: room.id, user_id: account.user.id).consent_status ==
             "withdrawn"

    assert {:ok, true} =
             Conversations.federation_erasure_pending?(account.tenant.id, :user, account.user.id)
  end

  test "a terminal create cannot be resurrected by an already queued worker", %{room: room} do
    id = Ecto.UUID.generate()

    command =
      Repo.insert!(
        Command.changeset(%Command{id: id}, %{
          tenant_id: room.tenant_id,
          room_id: room.id,
          kind: "create",
          request_key: "cancelled-create",
          payload_digest: SecretBox.hash("{}"),
          status: "cancelled",
          attempts: 0,
          generation: room.generation,
          expected_room_version: room.lock_version
        })
      )

    worker = RuntimePorts.job_worker!(:federation_command)
    assert {:ok, :recovery_only} = Conversations.prepare_federation_command(command.id, worker)
    assert Repo.get!(Command, command.id).status == "cancelled"

    assert {:error, :already_terminal} =
             Conversations.deliver_federation_command(command.id, worker, :recovery_only)

    refute_received {:federation_effect, _, _}
  end

  test "a current user hold permits the local fence but blocks destructive provider cleanup", %{
    account: account,
    room: room,
    subject: subject
  } do
    verified = Fixtures.step_up(account)

    assert {:ok, _} =
             CommsCore.Governance.create_legal_hold(
               %{
                 name: "Synthetic bridge hold",
                 reason: "Preserve synthetic federation evidence",
                 scope_type: "user",
                 subject_user_id: account.user.id,
                 idempotency_key: "federation-hold"
               },
               verified
             )

    assert {:ok, _} =
             Conversations.federation_consent(
               account.conversation.id,
               %{version: room.lock_version, accept: false},
               subject
             )

    leave = Repo.get_by!(Command, room_id: room.id, kind: "leave")

    assert {:error, :legal_hold_active} =
             Conversations.deliver_federation_command(
               leave.id,
               RuntimePorts.job_worker!(:federation_command),
               :recovery_only
             )

    assert Repo.get!(Command, leave.id).status == "pending"
    refute_received {:federation_effect, _, _}
  end

  test "user erasure preparation preserves another participant's consent and the pending barrier",
       %{account: account, room: room} do
    other = Fixtures.user_fixture(account)
    id = Ecto.UUID.generate()
    principal = "@another:example.org"

    Repo.insert!(
      Participant.changeset(%Participant{id: id}, %{
        tenant_id: room.tenant_id,
        room_id: room.id,
        user_id: other.user.id,
        principal_hash: SecretBox.hash(principal),
        principal_box: SecretBox.seal(room.tenant_id, id, "principal", principal),
        consent_status: "accepted"
      })
    )

    assert {:ok, {:ok, 1}} =
             Repo.transaction(fn ->
               Conversations.prepare_federation_erasure(account.tenant.id, :user, account.user.id)
             end)

    assert Repo.get_by!(Participant, room_id: room.id, user_id: account.user.id).consent_status ==
             "withdrawn"

    retained = Repo.get!(Participant, id)
    assert retained.consent_status == "accepted" and is_nil(retained.withdrawn_at)
    assert Repo.get!(Room, room.id).status == "active"

    assert {:ok, true} =
             Conversations.federation_erasure_pending?(account.tenant.id, :user, account.user.id)

    refute_received {:federation_effect, _, _}
  end

  test "actual registered Governance worker retains its completion barrier after local bridge cleanup",
       %{account: account, room: room} do
    subject = Fixtures.step_up(account)

    assert {:ok, %{request: request}} =
             Governance.create_deletion_request_view(
               %{
                 target_type: :conversation,
                 conversation_id: account.conversation.id,
                 reason: "Synthetic retained cross-server deletion uncertainty"
               },
               subject
             )

    assert {:ok, _} =
             Governance.transition_deletion_request_view(
               request.id,
               %{
                 version: request.version,
                 status: :approved,
                 transition_reason: "Scoped synthetic request independently verified"
               },
               subject
             )

    deletion_worker = RuntimePorts.job_worker!(:deletion)
    job = %Oban.Job{args: %{"deletion_request_id" => request.id}}
    assert {:snooze, 10} = deletion_worker.perform(job)

    assert {:ok, false} =
             Conversations.private_room_erasure_pending?(
               account.tenant.id,
               :conversation,
               account.conversation.id
             )

    assert {:ok, true} =
             Conversations.federation_erasure_pending?(
               account.tenant.id,
               :conversation,
               account.conversation.id
             )

    assert Repo.get!(Room, room.id).status == "fenced"
    refute_received {:federation_effect, _, _}

    bridge_worker = RuntimePorts.job_worker!(:federation_command)
    commands = Repo.all(from(c in Command, where: c.room_id == ^room.id))
    assert Enum.any?(commands, &(&1.kind == "close"))

    Enum.each(commands, fn command ->
      assert :ok = bridge_worker.perform(%Oban.Job{args: %{"command_id" => command.id}})
    end)

    retained = Repo.get!(Room, room.id)
    assert retained.local_cleanup_confirmed_at
    assert retained.remote_cleanup_state == "remote_unconfirmed"
    assert {:snooze, 10} = deletion_worker.perform(job)
    assert {:ok, requests} = Governance.list_deletion_request_views(%{}, subject)
    retained_request = Enum.find(requests, &(&1.id == request.id))
    assert retained_request.status == :in_progress
    assert is_nil(retained_request.completed_at)
    assert is_nil(retained_request.evidence[:media_erasure_version])
    assert is_nil(retained_request.evidence["media_erasure_version"])
  end

  test "registered worker retains the first-redaction marker across post-effect rollback and uncertain retries",
       %{
         account: account,
         room: room,
         subject: subject
       } do
    command = send_and_withdraw!(account, room, subject)
    worker = RuntimePorts.job_worker!(:federation_command)
    Process.put(:federation_redaction_outcome, :rollback)

    assert {:error, :synthetic_post_effect_failure} =
             worker.perform(%Oban.Job{args: %{"command_id" => command.id}})

    assert_received {:federation_redaction_request, first}
    assert first.effect_mode == :first_attempt
    assert first.bridge_user == room.provider_bridge_user
    retained = Repo.get!(Command, command.id)
    assert retained.status == "prepared" and retained.attempts == 1
    assert is_binary(retained.payload_box)

    Process.put(:federation_redaction_outcome, :unconfirmed)

    assert {:error, :federation_redaction_unconfirmed} =
             worker.perform(%Oban.Job{args: %{"command_id" => command.id}})

    assert_received {:federation_redaction_request, uncertain}
    assert uncertain.effect_mode == :recovery_only
    assert uncertain.transaction_id == first.transaction_id
    assert Repo.get!(Command, command.id).status == "uncertain"

    Process.put(:federation_redaction_outcome, :observed)
    assert :ok = worker.perform(%Oban.Job{args: %{"command_id" => command.id}})
    assert_received {:federation_redaction_request, recovered}
    assert recovered.effect_mode == :recovery_only
    assert Repo.get!(Command, command.id).status == "done"
    assert is_nil(Repo.get!(Command, command.id).payload_box)
    assert Repo.get!(Room, room.id).remote_cleanup_state == "remote_unconfirmed"

    assert {:ok, true} =
             Conversations.federation_erasure_pending?(account.tenant.id, :user, account.user.id)
  end

  test "a hold prevents the prepared redaction effect and preserves its original provider binding",
       %{
         account: account,
         room: room,
         subject: subject
       } do
    command = send_and_withdraw!(account, room, subject)
    verified = Fixtures.step_up(account)

    assert {:ok, _} =
             CommsCore.Governance.create_legal_hold(
               %{
                 name: "Synthetic redaction hold",
                 reason: "Preserve synthetic redaction evidence",
                 scope_type: "user",
                 subject_user_id: account.user.id,
                 idempotency_key: "federation-redaction-hold"
               },
               verified
             )

    worker = RuntimePorts.job_worker!(:federation_command)

    assert {:error, :legal_hold_active} =
             worker.perform(%Oban.Job{args: %{"command_id" => command.id}})

    assert Repo.get!(Command, command.id).status == "prepared"
    assert Repo.get!(Command, command.id).attempts == 1
    assert Repo.get!(Room, room.id).provider_bridge_user == "@bridge:example.org"
    refute_received {:federation_redaction_request, _}

    assert {:ok, true} =
             Conversations.federation_erasure_pending?(account.tenant.id, :user, account.user.id)
  end

  defp send_and_withdraw!(account, room, subject) do
    assert {:ok, queued} =
             Conversations.send_federation_message(
               account.conversation.id,
               %{
                 version: room.lock_version,
                 body: "synthetic erasable text",
                 idempotency_key: Ecto.UUID.generate()
               },
               subject
             )

    assert {:ok, :ok} =
             Conversations.deliver_federation_command(
               queued.id,
               RuntimePorts.job_worker!(:federation_command),
               :recovery_only
             )

    assert {:ok, _} =
             Conversations.federation_consent(
               account.conversation.id,
               %{version: room.lock_version, accept: false},
               subject
             )

    Repo.get_by!(Command, room_id: room.id, kind: "redact")
  end

  defp room_fixture(account) do
    trust =
      Repo.insert!(
        Trust.changeset(%Trust{}, %{
          tenant_id: account.tenant.id,
          domain: "remote.example.org",
          residency: "Synthetic region",
          cross_border_reason: "Reviewed synthetic processing",
          enabled: true
        })
      )

    id = Ecto.UUID.generate()

    room =
      Repo.insert!(
        Room.changeset(%Room{id: id}, %{
          tenant_id: account.tenant.id,
          conversation_id: account.conversation.id,
          trust_id: trust.id,
          created_by_user_id: account.user.id,
          alias_localpart: "kc_fed_" <> String.replace(id, "-", ""),
          provider_issuer: "https://matrix.example.org",
          provider_server_name: "example.org",
          provider_bridge_user: "@bridge:example.org",
          status: "active",
          provider_room_box:
            SecretBox.seal(account.tenant.id, id, "room", "!synthetic:example.org")
        })
      )

    principal = "@synthetic:example.org"
    pid = Ecto.UUID.generate()

    Repo.insert!(
      Participant.changeset(%Participant{id: pid}, %{
        tenant_id: account.tenant.id,
        room_id: room.id,
        user_id: account.user.id,
        principal_hash: SecretBox.hash(principal),
        principal_box: SecretBox.seal(account.tenant.id, pid, "principal", principal),
        consent_status: "accepted"
      })
    )

    room
  end
end
