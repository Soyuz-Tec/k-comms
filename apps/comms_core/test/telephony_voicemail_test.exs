defmodule CommsCore.TelephonyVoicemailTest.Control do
  @behaviour CommsCore.Telephony.ProviderControlPort.Contract
  def capabilities(), do: %{voicemail: %{supported: true}}
  def authorize_destination(_), do: :ok
  def verify_event(_, _), do: {:error, :invalid_provider_webhook}
  def cleanup_call(_), do: {:error, :telephony_provider_unavailable}
  def bound_call_status(_), do: {:error, :telephony_provider_unavailable}
  def execute_control(_), do: {:error, :telephony_control_unsupported}
end

defmodule CommsCore.TelephonyVoicemailTest.Provider do
  @behaviour CommsCore.Telephony.VoicemailProviderPort.Contract
  def ready?(), do: true

  def fetch(request),
    do:
      {:ok,
       %{
         body: "bounded-synthetic-recording",
         content_type: "audio/wav",
         duration_seconds: 2,
         recording_name: request.recording_name
       }}

  def delete(request) do
    if Process.get(:voicemail_source_error) do
      {:error, :voicemail_source_deletion_pending}
    else
      send(self(), {:source_deleted, request.recording_name})
      :ok
    end
  end
end

defmodule CommsCore.TelephonyVoicemailTest.Storage do
  @behaviour CommsCore.Telephony.VoicemailStoragePort.Contract
  def ready?(), do: true

  def ingest(%CommsCore.Telephony.VoicemailObject{} = object, _body) do
    send(self(), {:storage_ingested, object.object_key})

    {:ok,
     %{
       object
       | object_version_id: "exact-version",
         object_etag: "exact-etag",
         verified_checksum_sha256: object.checksum_sha256
     }}
  end

  def download(object),
    do:
      {:ok,
       %{
         url:
           "https://storage.example.test/" <>
             object.object_key <> "?versionId=" <> object.object_version_id,
         approved_origin: "https://storage.example.test",
         development_http: false,
         expires_at: DateTime.add(DateTime.utc_now(), 120, :second),
         expires_in: 120,
         content_type: "audio/wav"
       }}

  def delete(object) do
    if Process.get(:voicemail_storage_error) do
      {:error, :storage_unavailable}
    else
      send(self(), {:storage_deleted, object.object_key})
      :ok
    end
  end
end

defmodule CommsCore.TelephonyVoicemailTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsCore.{Accounts, Telephony}
  alias CommsCore.Accounts.Session
  alias CommsCore.Governance.{DeletionRequest, LegalHold}

  alias CommsCore.Telephony.{
    Call,
    Mailbox,
    Mailboxes,
    Number,
    Route,
    Voicemail,
    VoicemailErasurePlan,
    VoicemailObject,
    VoicemailRead,
    VoicemailProviderPort,
    VoicemailRequest,
    VoicemailStoragePort
  }

  alias CommsTestSupport.Fixtures
  alias CommsWorkers.TelephonyVoicemailWorker

  setup do
    values = %{
      telephony_control_adapter: CommsCore.TelephonyVoicemailTest.Control,
      voicemail_provider_adapter: CommsCore.TelephonyVoicemailTest.Provider,
      voicemail_storage_adapter: CommsCore.TelephonyVoicemailTest.Storage,
      voicemail_protection_adapter: CommsCore.Governance.VoicemailProtection
    }

    previous = Map.new(values, fn {key, _} -> {key, Application.fetch_env(:comms_core, key)} end)
    Enum.each(values, fn {key, value} -> Application.put_env(:comms_core, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_core, key, value)
        {key, :error} -> Application.delete_env(:comms_core, key)
      end)
    end)

    :ok
  end

  test "capture has a pre-effect identity and remains pending until approved storage is verified" do
    {_account, subject, v} = reserved()
    assert {:ok, %{messages: [pending]}} = Telephony.list_voicemails(subject, %{})
    assert pending.status == :pending
    assert {:error, :not_found} = Telephony.voicemail_playback(v.id, subject)

    assert {:ok, %VoicemailRequest{} = request} =
             Telephony.claim_voicemail(v.id, TelephonyVoicemailWorker)

    assert request.recording_name == "kc_vm_" <> String.replace(v.call_id, "-", "")
    assert request.object.object_key == VoicemailObject.key(v.tenant_id, v.id)
    assert :ok = TelephonyVoicemailWorker.perform(%Oban.Job{args: %{"voicemail_id" => v.id}})
    assert_receive {:source_deleted, _}
    stored = Repo.get!(Voicemail, v.id)
    assert stored.status == :available
    assert stored.object_version_id == "exact-version"
    assert stored.checksum_sha256 == stored.verified_checksum_sha256
    assert stored.provider_deleted_at
    assert {:ok, signed} = Telephony.voicemail_playback(v.id, subject)
    assert signed.url =~ "versionId=exact-version"
    refute signed.url =~ "ari"
    assert {:ok, %{read_at: nil}} = Telephony.list_voicemails(subject, %{}) |> first_message()
    assert {:ok, read} = Telephony.mark_voicemail_read(v.id, subject)
    assert read.read_at
    assert read.caller_number == Repo.get!(Call, v.call_id).to_number

    assert {:ok, %{caller_number: caller}} =
             Telephony.list_voicemails(subject, %{}) |> first_message()

    assert caller == read.caller_number
    assert {:ok, repeated} = Telephony.mark_voicemail_read(v.id, subject)
    assert repeated.read_at == read.read_at
  end

  test "incoming voicemail exposes only its authorized external caller number" do
    {_account, subject, v} = reserved()

    Repo.get!(Call, v.call_id)
    |> Call.changeset(%{
      direction: :inbound,
      from_number: "+14155550999",
      to_number: "+14155550100"
    })
    |> Repo.update!()

    assert {:ok, %{caller_number: "+14155550999"}} =
             Telephony.list_voicemails(subject, %{}) |> first_message()

    assert {:ok, %{messages: []}} =
             Telephony.list_voicemails(Fixtures.subject(Fixtures.account_fixture()), %{})
  end

  test "idempotent completion rejects another tenant, recording key and object version" do
    {_account, _subject, v} = reserved()
    {:ok, request} = Telephony.claim_voicemail(v.id, TelephonyVoicemailWorker)
    {:ok, object} = VoicemailStoragePort.ingest(request.object, "bounded-synthetic-recording")
    result = %{object: object, duration_seconds: 2}

    assert {:error, :voicemail_storage_identity_invalid} =
             Telephony.complete_voicemail(
               v.id,
               {:ok, %{result | object: %{object | tenant_id: Ecto.UUID.generate()}}},
               TelephonyVoicemailWorker
             )

    assert {:error, :voicemail_storage_identity_invalid} =
             Telephony.complete_voicemail(
               v.id,
               {:ok, %{result | object: %{object | object_key: v.tenant_id <> "/foreign.wav"}}},
               TelephonyVoicemailWorker
             )

    assert {:ok, :available} =
             Telephony.complete_voicemail(v.id, {:ok, result}, TelephonyVoicemailWorker)

    assert {:ok, :available} =
             Telephony.complete_voicemail(v.id, {:ok, result}, TelephonyVoicemailWorker)

    assert {:error, :voicemail_storage_identity_invalid} =
             Telephony.complete_voicemail(
               v.id,
               {:ok, %{result | object: %{object | object_version_id: "different-version"}}},
               TelephonyVoicemailWorker
             )

    assert Repo.get!(Voicemail, v.id).object_version_id == "exact-version"
  end

  test "foreign tenants, revoked sessions and unregistered workers cannot retrieve or erase messages" do
    {account, subject, v} = reserved()
    available!(v)
    foreign = Fixtures.account_fixture()
    outsider = Fixtures.subject(foreign)
    assert {:ok, %{messages: []}} = Telephony.list_voicemails(outsider, %{})
    assert {:error, :not_found} = Telephony.voicemail_playback(v.id, outsider)
    assert {:error, :not_found} = Telephony.mark_voicemail_read(v.id, outsider)
    assert {:error, :not_found} = Telephony.delete_voicemail(v.id, outsider)
    assert {:error, :forbidden} = Telephony.claim_voicemail(v.id, __MODULE__)
    assert {:error, :forbidden} = Telephony.purge_voicemail(v.id, __MODULE__)

    Repo.get!(Session, account.session.id)
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, :forbidden} = Telephony.voicemail_playback(v.id, subject)
    assert {:error, :forbidden} = Telephony.mark_voicemail_read(v.id, subject)
    assert {:error, :forbidden} = Telephony.delete_voicemail(v.id, subject)
  end

  test "shared-line access follows current active route membership and read state belongs to each member" do
    {account, subject, v} = reserved()
    available!(v)
    %{user: member} = Fixtures.user_fixture(account)
    suffix = member.email |> String.split("@") |> hd() |> String.replace_prefix("member-", "")

    {:ok, auth} =
      Accounts.authenticate_view(
        account.tenant.slug,
        member.email,
        "correct-horse-battery-" <> suffix,
        %{name: "Shared line", platform: "test"}
      )

    {:ok, context} = Accounts.access_context(auth.session_id)
    number = Repo.get_by!(Number, tenant_id: account.tenant.id)

    route =
      %Route{}
      |> Route.changeset(%{
        tenant_id: account.tenant.id,
        number_id: number.id,
        name: "Shared",
        mode: :shared_line,
        policy: :simultaneous,
        member_ids: [member.id, account.user.id],
        enabled: true
      })
      |> Repo.insert!()

    Repo.get!(Call, v.call_id) |> Call.changeset(%{route_id: route.id}) |> Repo.update!()
    assert {:ok, _} = Telephony.voicemail_playback(v.id, context.subject)

    assert {:ok, %{caller_number: caller}} =
             Telephony.list_voicemails(context.subject, %{}) |> first_message()

    assert caller == Repo.get!(Call, v.call_id).to_number
    assert {:ok, %{read_at: read}} = Telephony.mark_voicemail_read(v.id, context.subject)
    assert read
    assert {:ok, %{read_at: nil}} = Telephony.list_voicemails(subject, %{}) |> first_message()
    route |> Route.changeset(%{member_ids: [account.user.id]}) |> Repo.update!()
    assert {:ok, %{messages: []}} = Telephony.list_voicemails(context.subject, %{})
    assert {:error, :not_found} = Telephony.voicemail_playback(v.id, context.subject)
    assert {:error, :not_found} = Telephony.delete_voicemail(v.id, context.subject)
  end

  test "legal hold blocks user deletion and every provider or storage erase" do
    {account, subject, v} = reserved()
    available!(v)

    hold =
      %LegalHold{}
      |> LegalHold.changeset(%{
        tenant_id: account.tenant.id,
        created_by_user_id: account.user.id,
        scope_type: :tenant,
        name: "Preserve voice",
        reason: "Synthetic preservation",
        starts_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert {:error, :voicemail_legal_hold} = Telephony.delete_voicemail(v.id, subject)
    assert {:ok, :held} = Telephony.cleanup_voicemail_source(v.id, TelephonyVoicemailWorker)

    v
    |> Voicemail.changeset(%{retention_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})
    |> Repo.update!()

    assert {:ok, :held} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
    refute_received {:source_deleted, _}
    refute_received {:storage_deleted, _}

    hold
    |> LegalHold.changeset(%{status: :released, released_at: DateTime.utc_now()})
    |> Repo.update!()

    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
    assert_receive {:source_deleted, _}
    assert_receive {:storage_deleted, _}
  end

  test "deletion failure is retryable and never advertises erased storage prematurely" do
    {_account, subject, v} = reserved()
    available!(v)
    assert {:ok, :deleting} = Telephony.delete_voicemail(v.id, subject)
    Process.put(:voicemail_storage_error, true)

    assert {:error, :storage_unavailable} =
             Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)

    assert Repo.get!(Voicemail, v.id).status == :deleting
    assert {:error, :not_found} = Telephony.voicemail_playback(v.id, subject)
    Process.delete(:voicemail_storage_error)
    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
  end

  test "capture reconciliation, future retention and immediate deletion have distinct durable job identities" do
    {_account, subject, v} = reserved()
    assert {:ok, _} = Repo.transaction(fn -> Mailboxes.reserve!(Repo.get!(Call, v.call_id)) end)

    jobs =
      Repo.all(
        from(j in Oban.Job,
          where:
            j.worker == "CommsWorkers.TelephonyVoicemailWorker" and
              fragment("?->>'voicemail_id'", j.args) == ^v.id
        )
      )

    assert Enum.sort(Enum.map(jobs, & &1.args["trigger"])) == ["reconcile", "retention"]
    retention = Enum.find(jobs, &(&1.args["trigger"] == "retention"))
    assert DateTime.compare(retention.scheduled_at, v.retention_expires_at) == :eq
    capture = Enum.find(jobs, &(&1.args["trigger"] == "reconcile"))

    capture
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, :deleting} = Telephony.delete_voicemail(v.id, subject)
    assert {:ok, :deleting} = Telephony.delete_voicemail(v.id, subject)

    deletion =
      Repo.all(
        from(j in Oban.Job,
          where:
            j.worker == "CommsWorkers.TelephonyVoicemailWorker" and
              fragment("?->>'voicemail_id'", j.args) == ^v.id and
              fragment("?->>'trigger'", j.args) == "delete"
        )
      )

    assert [immediate] = deletion
    assert DateTime.diff(immediate.scheduled_at, DateTime.utc_now(), :second) <= 0
  end

  test "a stale recording fetched before deletion cannot upload after protected purge" do
    {_account, subject, v} = reserved()
    {:ok, request} = Telephony.claim_voicemail(v.id, TelephonyVoicemailWorker)
    {:ok, media} = VoicemailProviderPort.fetch(request)
    assert {:ok, :deleting} = Telephony.delete_voicemail(v.id, subject)
    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)

    assert {:error, :voicemail_capture_cancelled} =
             Telephony.store_voicemail(v.id, media, TelephonyVoicemailWorker)

    assert Repo.get!(Voicemail, v.id).status == :deleted
    assert Repo.get!(Voicemail, v.id).object_version_id == nil
  end

  test "elapsed recording deadline preserves unavailable provider data until authenticated absence is known" do
    {_account, _subject, v} = reserved()
    deadline = DateTime.add(DateTime.utc_now(), -1, :second)
    call = Repo.get!(Call, v.call_id)
    times = %{started_at: DateTime.add(deadline, -200, :second), expires_at: deadline}

    times =
      if call.answered_at,
        do: Map.put(times, :answered_at, DateTime.add(deadline, -190, :second)),
        else: times

    call |> Call.changeset(times) |> Repo.update!()

    # Move the whole capture interval into the past, preserving the production
    # invariant that the fixed expiry is later than the original call start.
    v
    |> Voicemail.changeset(%{recording_deadline: deadline})
    |> Ecto.Changeset.change(inserted_at: DateTime.add(deadline, -180, :second))
    |> Repo.update!()

    assert {:ok, %VoicemailRequest{operation: :reconcile}} =
             Telephony.claim_voicemail(v.id, TelephonyVoicemailWorker)

    assert {:ok, :pending} =
             Telephony.complete_voicemail(
               v.id,
               {:error, :telephony_provider_unavailable},
               TelephonyVoicemailWorker
             )

    assert Repo.get!(Voicemail, v.id).status == :pending

    assert {:error, :voicemail_not_deletable} =
             Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)

    refute_received {:source_deleted, _}
    refute_received {:storage_deleted, _}

    assert {:ok, :deleting} =
             Telephony.complete_voicemail(v.id, {:error, :not_found}, TelephonyVoicemailWorker)

    assert {:ok, %VoicemailRequest{operation: :delete}} =
             Telephony.claim_voicemail(v.id, TelephonyVoicemailWorker)

    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
  end

  test "disabled storage cannot enable or reserve a mailbox, cursor and media bounds fail closed" do
    {_account, subject, v} = reserved()
    assert {:error, :invalid_voicemail_limit} = Telephony.list_voicemails(subject, %{limit: 101})

    assert {:error, :invalid_voicemail_cursor} =
             Telephony.list_voicemails(subject, %{cursor: "../call"})

    assert {:error, :invalid_voicemail_media} =
             VoicemailStoragePort.ingest(
               %VoicemailObject{
                 tenant_id: v.tenant_id,
                 voicemail_id: v.id,
                 object_key: v.object_key
               },
               ""
             )

    request = %VoicemailRequest{
      id: v.id,
      tenant_id: v.tenant_id,
      call_id: v.call_id,
      recording_name: "kc_vm_wrong",
      operation: :reconcile
    }

    assert {:error, :invalid_voicemail_media} = VoicemailProviderPort.fetch(request)
    Application.delete_env(:comms_core, :voicemail_storage_adapter)
    refute Mailboxes.ready?()
    {:ok, %{mailbox: box}} = Telephony.mailbox_config(subject)

    assert {:ok, %{enabled: false}} =
             Telephony.save_mailbox(
               %{
                 user_id: box.user_id,
                 version: box.version,
                 enabled: false,
                 retention_days: 30,
                 notice_media: box.notice_media,
                 reason: "Disable capture"
               },
               subject
             )

    assert {:error, :telephony_mailbox_unavailable} =
             Repo.transaction(fn -> Mailboxes.reserve!(Repo.get!(Call, v.call_id)) end)
  end

  test "governance preparation hides shared media immediately and waits for provider, every object version and read-state purge" do
    {account, subject, v} = reserved()
    available!(v)
    shared = shared_subject!(account, v)
    assert {:ok, _} = Telephony.mark_voicemail_read(v.id, subject)
    assert {:ok, _} = Telephony.mark_voicemail_read(v.id, shared)
    assert Repo.aggregate(from(r in VoicemailRead, where: r.voicemail_id == ^v.id), :count) == 2

    assert {:ok, {:ok, %VoicemailErasurePlan{pending_voicemail_count: 1}}} =
             Repo.transaction(fn ->
               Telephony.prepare_governance_erasure(v.tenant_id, :user, v.user_id)
             end)

    assert Repo.get!(Voicemail, v.id).erasure_requested_at

    for current <- [subject, shared] do
      assert {:ok, %{messages: []}} = Telephony.list_voicemails(current, %{})
      assert {:error, :not_found} = Telephony.voicemail_playback(v.id, current)
      assert {:error, :not_found} = Telephony.mark_voicemail_read(v.id, current)
    end

    assert erasure_pending?(v.tenant_id, v.user_id)

    # DELETE acceptance is not proof that an active recording or stored source
    # has disappeared. Storage and read states must survive this retry.
    Process.put(:voicemail_source_error, true)

    assert {:error, :voicemail_source_deletion_pending} =
             Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)

    refute_received {:storage_deleted, _}
    assert erasure_pending?(v.tenant_id, v.user_id)
    assert Repo.aggregate(from(r in VoicemailRead, where: r.voicemail_id == ^v.id), :count) == 2
    Process.delete(:voicemail_source_error)

    Process.put(:voicemail_storage_error, true)

    assert {:error, :storage_unavailable} =
             Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)

    assert Repo.get!(Voicemail, v.id).erasure_verified_at == nil
    assert erasure_pending?(v.tenant_id, v.user_id)
    Process.delete(:voicemail_storage_error)

    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
    assert_receive {:storage_deleted, _}
    assert Repo.aggregate(from(r in VoicemailRead, where: r.voicemail_id == ^v.id), :count) == 0
    assert Repo.get!(Voicemail, v.id).erasure_verified_at
    refute erasure_pending?(v.tenant_id, v.user_id)

    assert {:ok, {:ok, %VoicemailErasurePlan{pending_voicemail_count: 0}}} =
             Repo.transaction(fn ->
               Telephony.prepare_governance_erasure(v.tenant_id, :user, v.user_id)
             end)
  end

  test "an erasing capture cannot be restarted, uploaded or completed by a stale control or ingestion worker" do
    {_account, _subject, v} = reserved()
    {:ok, request} = Telephony.claim_voicemail(v.id, TelephonyVoicemailWorker)
    {:ok, media} = VoicemailProviderPort.fetch(request)

    assert {:ok, {:ok, %VoicemailErasurePlan{pending_voicemail_count: 1}}} =
             Repo.transaction(fn ->
               Telephony.prepare_governance_erasure(v.tenant_id, :user, v.user_id)
             end)

    assert {:error, :voicemail_capture_cancelled} =
             Telephony.store_voicemail(v.id, media, TelephonyVoicemailWorker)

    refute_received {:storage_ingested, _}

    assert {:error, :voicemail_capture_cancelled} =
             Telephony.complete_voicemail(v.id, {:error, :not_found}, TelephonyVoicemailWorker)

    assert {:error, :voicemail_capture_cancelled} =
             Repo.transaction(fn ->
               call = Repo.get!(Call, v.call_id)
               Mailboxes.lock_capture_effect_policy!(call)
               Mailboxes.assert_capture_effect_allowed!(call)
             end)

    assert {:error, :telephony_mailbox_unavailable} =
             Repo.transaction(fn -> Mailboxes.reserve!(Repo.get!(Call, v.call_id)) end)

    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)

    assert {:error, :voicemail_capture_cancelled} =
             Telephony.store_voicemail(v.id, media, TelephonyVoicemailWorker)

    assert Repo.get!(Voicemail, v.id).object_version_id == nil
  end

  test "hold subjects include original assigned users after reassignment and the current mailbox owner" do
    {account, subject, v} = reserved(assigned: true)
    available!(v)
    assigned = account.voicemail_assigned_user
    assert assigned.id in v.protected_user_ids
    %{user: current_box_owner} = Fixtures.user_fixture(account)

    Repo.get!(Call, v.call_id)
    |> Call.changeset(%{user_id: account.user.id})
    |> Repo.update!()

    hold = user_hold!(account, assigned.id)

    assert {:error, :voicemail_legal_hold} = Telephony.delete_voicemail(v.id, subject)
    assert {:ok, :held} = Telephony.cleanup_voicemail_source(v.id, TelephonyVoicemailWorker)

    assert {:ok, {:error, :legal_hold_active}} =
             Repo.transaction(fn ->
               Telephony.prepare_governance_erasure(v.tenant_id, :user, v.user_id)
             end)

    assert Repo.get!(Voicemail, v.id).erasure_requested_at == nil
    release_hold!(hold)

    # A reassigned mailbox owner must protect and govern the same media even
    # though they were not the owner when the recording was captured.
    box = Repo.get!(Mailbox, v.mailbox_id)
    box |> Mailbox.changeset(%{user_id: current_box_owner.id}) |> Repo.update!()
    hold = user_hold!(account, current_box_owner.id)
    assert {:error, :voicemail_legal_hold} = Telephony.delete_voicemail(v.id, subject)

    assert {:ok, {:error, :legal_hold_active}} =
             Repo.transaction(fn ->
               Telephony.prepare_governance_erasure(v.tenant_id, :user, current_box_owner.id)
             end)

    refute_received {:source_deleted, _}
    refute_received {:storage_deleted, _}
    release_hold!(hold)

    assert {:ok, {:ok, %VoicemailErasurePlan{pending_voicemail_count: 1}}} =
             Repo.transaction(fn ->
               Telephony.prepare_governance_erasure(v.tenant_id, :user, current_box_owner.id)
             end)

    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
  end

  test "erasure scope includes the associated call user, rejects foreign tenants, and requires a transaction" do
    {account, _subject, v} = reserved()
    %{user: assigned} = Fixtures.user_fixture(account)
    Repo.get!(Call, v.call_id) |> Call.changeset(%{user_id: assigned.id}) |> Repo.update!()

    assert {:error, :transaction_required} =
             Telephony.prepare_governance_erasure(v.tenant_id, :user, assigned.id)

    assert {:error, :transaction_required} =
             Telephony.governance_erasure_pending?(v.tenant_id, :user, assigned.id)

    assert {:ok, {:error, :invalid_governance_target}} =
             Repo.transaction(fn ->
               Telephony.prepare_governance_erasure(v.tenant_id, :user, "invalid")
             end)

    for target <- [:conversation, :message] do
      assert {:ok, {:ok, %VoicemailErasurePlan{pending_voicemail_count: 0}}} =
               Repo.transaction(fn ->
                 Telephony.prepare_governance_erasure(v.tenant_id, target, Ecto.UUID.generate())
               end)
    end

    assert {:ok, {:ok, %VoicemailErasurePlan{pending_voicemail_count: 0}}} =
             Repo.transaction(fn ->
               Telephony.prepare_governance_erasure(Ecto.UUID.generate(), :user, assigned.id)
             end)

    assert Repo.get!(Voicemail, v.id).erasure_requested_at == nil

    assert {:ok, {:ok, %VoicemailErasurePlan{pending_voicemail_count: 1}}} =
             Repo.transaction(fn ->
               Telephony.prepare_governance_erasure(v.tenant_id, :user, assigned.id)
             end)
  end

  test "approved user erasure blocks fresh reservations and stale output before the erasure worker prepares media" do
    {account, subject, v} = reserved()
    available!(v)

    %DeletionRequest{}
    |> DeletionRequest.changeset(%{
      tenant_id: v.tenant_id,
      requested_by_user_id: account.user.id,
      subject_user_id: v.user_id,
      target_type: :user,
      reason: "Approved synthetic erasure",
      status: :approved
    })
    |> Repo.insert!()

    assert {:error, :voicemail_capture_cancelled} =
             Repo.transaction(fn -> Mailboxes.reserve!(Repo.get!(Call, v.call_id)) end)

    assert {:error, :not_found} = Telephony.voicemail_playback(v.id, subject)
    assert {:error, :not_found} = Telephony.mark_voicemail_read(v.id, subject)

    assert {:error, :voicemail_capture_cancelled} =
             Telephony.store_voicemail(v.id, %{}, TelephonyVoicemailWorker)
  end

  test "legacy deleted metadata is pending until fresh provider and object absence receipts are recorded" do
    {_account, _subject, v} = reserved()

    v
    |> Voicemail.changeset(%{status: :deleted, deleted_at: DateTime.utc_now()})
    |> Repo.update!()

    assert erasure_pending?(v.tenant_id, v.user_id)

    assert {:ok, {:ok, %VoicemailErasurePlan{pending_voicemail_count: 1}}} =
             Repo.transaction(fn ->
               Telephony.prepare_governance_erasure(v.tenant_id, :user, v.user_id)
             end)

    Process.put(:voicemail_source_error, true)

    assert {:error, :voicemail_source_deletion_pending} =
             Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)

    assert erasure_pending?(v.tenant_id, v.user_id)
    Process.delete(:voicemail_source_error)
    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
    refute erasure_pending?(v.tenant_id, v.user_id)
  end

  test "rollback hazards persist through failed and deleting states until physical erasure including every read state is verified" do
    assert Telephony.rollback_voicemail_hazard_count() == 0
    {_account, subject, v} = reserved()
    assert Telephony.rollback_voicemail_hazard_count() == 1
    available!(v)
    assert Telephony.rollback_voicemail_hazard_count() == 1
    assert {:ok, _} = Telephony.mark_voicemail_read(v.id, subject)
    v |> Voicemail.changeset(%{status: :failed}) |> Repo.update!()
    assert Telephony.rollback_voicemail_hazard_count() == 1
    assert {:ok, :deleting} = Telephony.delete_voicemail(v.id, subject)
    assert Telephony.rollback_voicemail_hazard_count() == 1
    Process.put(:voicemail_source_error, true)

    assert {:error, :voicemail_source_deletion_pending} =
             Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)

    assert Telephony.rollback_voicemail_hazard_count() == 1
    Process.delete(:voicemail_source_error)
    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
    assert Telephony.rollback_voicemail_hazard_count() == 0

    # Historical deleted metadata without physical evidence must still prevent
    # selection of a release that lacks the voicemail reconciliation worker.
    Repo.get!(Voicemail, v.id)
    |> Voicemail.changeset(%{erasure_verified_at: nil, provider_deleted_at: nil})
    |> Repo.update!()

    assert Telephony.rollback_voicemail_hazard_count() == 1
    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
    assert Telephony.rollback_voicemail_hazard_count() == 0

    # The media receipt alone cannot cover leftover personal read-state rows.
    %VoicemailRead{}
    |> VoicemailRead.changeset(%{
      tenant_id: v.tenant_id,
      voicemail_id: v.id,
      user_id: v.user_id,
      read_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert Telephony.rollback_voicemail_hazard_count() == 1
    assert {:ok, :deleted} = Telephony.purge_voicemail(v.id, TelephonyVoicemailWorker)
    assert Telephony.rollback_voicemail_hazard_count() == 0
  end

  test "caller-only capture projection is bound to the exact recording and never extends the original deadline" do
    {_account, _subject, v} = reserved(expires_in: 900)
    call = Repo.get!(Call, v.call_id)
    assert DateTime.compare(call.expires_at, v.recording_deadline) == :eq
    assert {:pending, deadline} = Mailboxes.capture_lifecycle(call)
    assert DateTime.compare(deadline, v.recording_deadline) == :eq
    assert :absent = Mailboxes.capture_lifecycle(%{call | tenant_id: Ecto.UUID.generate()})
    assert :absent = Mailboxes.capture_lifecycle(%{call | id: Ecto.UUID.generate()})

    bindings = %{"external" => "exact-caller", "recording" => v.recording_name}
    call |> Call.changeset(%{pbx_state: bindings, control_state: "voicemail"}) |> Repo.update!()
    assert {:pending, ^deadline} = Mailboxes.capture_lifecycle(Repo.get!(Call, call.id))

    assert :complete =
             Mailboxes.capture_lifecycle(%{
               call
               | pbx_state: %{bindings | "recording" => "another-recording"}
             })

    assert :complete =
             Mailboxes.capture_lifecycle(%{call | pbx_state: %{"external" => "exact-caller"}})

    shortened = DateTime.add(deadline, -90, :second)
    Repo.get!(Call, call.id) |> Call.changeset(%{expires_at: shortened}) |> Repo.update!()
    assert {:ok, _} = Repo.transaction(fn -> Mailboxes.reserve!(Repo.get!(Call, call.id)) end)
    assert DateTime.compare(Repo.get!(Call, call.id).expires_at, shortened) == :eq
    assert DateTime.compare(Repo.get!(Voicemail, v.id).recording_deadline, deadline) == :eq
    assert {:pending, ^shortened} = Mailboxes.capture_lifecycle(Repo.get!(Call, call.id))

    available!(v)
    assert :complete = Mailboxes.capture_lifecycle(Repo.get!(Call, call.id))

    for status <- [:failed, :deleting, :deleted] do
      Repo.get!(Voicemail, v.id) |> Voicemail.changeset(%{status: status}) |> Repo.update!()
      assert :complete = Mailboxes.capture_lifecycle(Repo.get!(Call, call.id))
    end

    Repo.get!(Voicemail, v.id)
    |> Voicemail.changeset(%{status: :pending, erasure_requested_at: DateTime.utc_now()})
    |> Repo.update!()

    assert :complete = Mailboxes.capture_lifecycle(Repo.get!(Call, call.id))
  end

  defp erasure_pending?(tenant_id, user_id) do
    {:ok, {:ok, pending}} =
      Repo.transaction(fn -> Telephony.governance_erasure_pending?(tenant_id, :user, user_id) end)

    pending
  end

  defp user_hold!(account, user_id) do
    %LegalHold{}
    |> LegalHold.changeset(%{
      tenant_id: account.tenant.id,
      created_by_user_id: account.user.id,
      scope_type: :user,
      subject_user_id: user_id,
      name: "Preserve subject",
      reason: "Synthetic preservation",
      starts_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp release_hold!(hold),
    do:
      hold
      |> LegalHold.changeset(%{status: :released, released_at: DateTime.utc_now()})
      |> Repo.update!()

  defp shared_subject!(account, v) do
    %{user: member} = Fixtures.user_fixture(account)
    suffix = member.email |> String.split("@") |> hd() |> String.replace_prefix("member-", "")

    {:ok, auth} =
      Accounts.authenticate_view(
        account.tenant.slug,
        member.email,
        "correct-horse-battery-" <> suffix,
        %{name: "Shared line", platform: "test"}
      )

    {:ok, context} = Accounts.access_context(auth.session_id)

    route =
      %Route{}
      |> Route.changeset(%{
        tenant_id: account.tenant.id,
        number_id: Repo.get_by!(Number, tenant_id: account.tenant.id).id,
        name: "Shared",
        mode: :shared_line,
        policy: :simultaneous,
        member_ids: [member.id, account.user.id],
        enabled: true
      })
      |> Repo.insert!()

    Repo.get!(Call, v.call_id) |> Call.changeset(%{route_id: route.id}) |> Repo.update!()
    context.subject
  end

  defp reserved(opts \\ []) do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)

    {:ok, _} =
      Telephony.provision(
        %{
          phone_number: "+14155550100",
          extension: "101",
          user_id: account.user.id,
          inbound_trunk_id: "ST_inbound",
          outbound_trunk_id: "ST_outbound",
          reason: "Synthetic line"
        },
        subject
      )

    {:ok, _} =
      Telephony.save_mailbox(
        %{
          user_id: account.user.id,
          enabled: true,
          retention_days: 30,
          notice_media: "sound:custom/recording-notice",
          reason: "Synthetic voicemail"
        },
        subject
      )

    {:ok, call, :created} =
      Telephony.start_outbound(
        %{destination: "+14155550200", idempotency_key: "voicemail-test"},
        subject
      )

    if seconds = Keyword.get(opts, :expires_in) do
      Repo.get!(Call, call.id)
      |> Call.changeset(%{expires_at: DateTime.add(DateTime.utc_now(), seconds, :second)})
      |> Repo.update!()
    end

    account =
      if Keyword.get(opts, :assigned, false) do
        %{user: assigned} = Fixtures.user_fixture(account)
        Repo.get!(Call, call.id) |> Call.changeset(%{user_id: assigned.id}) |> Repo.update!()
        Map.put(account, :voicemail_assigned_user, assigned)
      else
        account
      end

    {:ok, _} = Repo.transaction(fn -> Mailboxes.reserve!(Repo.get!(Call, call.id)) end)
    {account, subject, Repo.get_by!(Voicemail, call_id: call.id)}
  end

  defp available!(v) do
    {:ok, request} = Telephony.claim_voicemail(v.id, TelephonyVoicemailWorker)
    {:ok, object} = VoicemailStoragePort.ingest(request.object, "bounded-synthetic-recording")

    {:ok, :available} =
      Telephony.complete_voicemail(
        v.id,
        {:ok, %{object: object, duration_seconds: 2}},
        TelephonyVoicemailWorker
      )
  end

  defp first_message({:ok, %{messages: [message]}}), do: {:ok, message}
end
