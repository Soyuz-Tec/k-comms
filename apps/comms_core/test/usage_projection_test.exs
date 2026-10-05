defmodule CommsCore.UsageProjectionTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{
    Accounts,
    Attachments,
    AudioCalls,
    Conversations,
    Governance,
    Messaging,
    RuntimePorts,
    Telephony
  }

  alias CommsCore.Accounts.{Session, User}
  alias CommsCore.Attachments.Attachment
  alias CommsCore.AudioCalls.AudioCall
  alias CommsCore.Messaging.Message
  alias CommsCore.Telephony.{Call, Number}
  alias CommsTestSupport.Fixtures
  @moduletag :integration

  test "each owner rejects foreign tenant, stale step-up, and limited tenant privileges" do
    account = Fixtures.account_fixture()
    other = Fixtures.account_fixture()
    day = Date.utc_today()
    subject = Fixtures.subject(account)

    for {facade, query} <- queries(account.tenant.id, day, day) do
      assert {:error, :step_up_required} = facade.usage_projection(query, subject)
    end

    subject = Fixtures.step_up(account)

    for {facade, query} <- queries(other.tenant.id, day, day) do
      assert {:error, :forbidden} = facade.usage_projection(query, subject)
    end

    Repo.update_all(from(u in User, where: u.id == ^account.user.id), set: [role: :admin])

    for {facade, query} <- queries(account.tenant.id, day, day) do
      assert {:ok, _} = facade.usage_projection(query, subject)
    end

    for {role, scope} <- [
          {:member, :workspace},
          {:compliance_admin, :workspace},
          {:owner, :conversation_only}
        ] do
      Repo.update_all(from(u in User, where: u.id == ^account.user.id),
        set: [role: role, access_scope: scope]
      )

      for {facade, query} <- queries(account.tenant.id, day, day) do
        assert {:error, :forbidden} = facade.usage_projection(query, subject)
      end
    end
  end

  test "UTC date bounds are inclusive and capped before owner queries" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    through = Date.utc_today()

    for {facade, query} <- queries(account.tenant.id, Date.add(through, -30), through) do
      assert {:ok, result} = facade.usage_projection(query, subject)
      assert length(result.daily) == 31
      assert hd(result.daily).date == Date.add(through, -30)
      assert List.last(result.daily).date == through

      assert {:error, :invalid_usage_query} =
               facade.usage_projection(%{query | from: Date.add(through, -31)}, subject)

      assert {:error, :invalid_usage_query} =
               facade.usage_projection(%{query | through: Date.add(through, 1)}, subject)

      assert {:error, :invalid_usage_query} =
               facade.usage_projection(%{query | from: Date.add(through, 1)}, subject)
    end
  end

  test "active identity counts exclude guests and separate active service identities" do
    account = Fixtures.account_fixture()
    Fixtures.user_fixture(account)
    service = Fixtures.user_fixture(account, %{account_type: :service}).user

    guest =
      %User{}
      |> User.guest_changeset(%{
        tenant_id: account.tenant.id,
        external_subject: "usage-guest-#{Ecto.UUID.generate()}",
        display_name: "Usage Guest",
        guest_expires_at: DateTime.add(DateTime.utc_now(), 600)
      })
      |> Repo.insert!()

    Fixtures.user_fixture(account, %{status: :suspended})
    subject = Fixtures.step_up(account)
    assert {:ok, result} = Accounts.usage_projection(query(Accounts, account.tenant.id), subject)
    assert result.current == %{active_humans: 2, active_services: 1}

    Repo.update_all(from(u in User, where: u.id in ^[service.id, guest.id]),
      set: [status: :deleted]
    )

    assert {:ok, after_erasure} =
             Accounts.usage_projection(query(Accounts, account.tenant.id), subject)

    assert after_erasure.current == %{active_humans: 2, active_services: 0}

    assert Map.keys(Map.from_struct(after_erasure)) |> Enum.sort() == [
             :current,
             :daily,
             :earliest_retained_at,
             :observed_at
           ]
  end

  test "creation bins remain UTC under a non-UTC database session and exclude the next midnight" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    day = Date.add(Date.utc_today(), -2)
    midnight = utc(day)
    previous = message(account, DateTime.add(midnight, -1), 1)
    message(account, midnight, 2)
    message(account, DateTime.add(midnight, 86_399), 3)
    following = message(account, DateTime.add(midnight, 86_400), 4)
    Repo.query!("SET LOCAL TIME ZONE 'Pacific/Auckland'")

    assert {:ok, result} =
             Messaging.usage_projection(query(Messaging, account.tenant.id, day, day), subject)

    assert [%{date: ^day, metrics: %{created: 2, current_active: 2}}] = result.daily
    assert result.current.retained_messages == 4
    assert result.earliest_retained_at == previous.inserted_at
    assert following.inserted_at == DateTime.add(midnight, 86_400)
  end

  test "governed message erasure changes aggregate status without exposing retained text" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    message = message(account, now, 1)
    assert {:ok, before} = Messaging.usage_projection(query(Messaging, account.tenant.id), subject)
    assert hd(before.daily).metrics.current_active == 1

    {:ok, %{request: request}} =
      Governance.create_deletion_request(
        %{
          target_type: "message",
          message_id: message.id,
          reason: "Usage privacy qualification",
          idempotency_key: Ecto.UUID.generate()
        },
        subject
      )

    {:ok, _} =
      Governance.transition_deletion_request(
        request.id,
        %{version: request.lock_version, status: "approved", transition_reason: "Qualified"},
        subject
      )

    {:ok, claim} =
      Governance.claim_deletion_request(request.id, RuntimePorts.job_worker!(:deletion))

    assert {:ok, _} =
             Governance.complete_deletion_request(
               claim.request_id,
               claim.expected_version,
               %{deleted_object_count: 0},
               RuntimePorts.job_worker!(:deletion)
             )

    assert {:ok, after_erasure} =
             Messaging.usage_projection(query(Messaging, account.tenant.id), subject)

    assert hd(after_erasure.daily).metrics.current_active == 0
    assert hd(after_erasure.daily).metrics.current_deleted == 1
    assert after_erasure.current.retained_messages == 1
    refute inspect(after_erasure) =~ "sensitive usage body"
    refute inspect(after_erasure) =~ message.id
  end

  test "only ready verified originals contribute retained bytes and deleted objects drop out" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    ready = attachment(account, :ready, 4_294_967_300)
    attachment(account, :pending, 700)
    attachment(account, :deleted, 900)

    assert {:ok, result} =
             Attachments.usage_projection(query(Attachments, account.tenant.id), subject)

    assert result.current == %{ready_retained_count: 1, ready_retained_bytes: 4_294_967_300}
    assert hd(result.daily).metrics == %{created: 3, ready_count: 1, ready_bytes: 4_294_967_300}
    Repo.update_all(from(a in Attachment, where: a.id == ^ready.id), set: [status: :deleted])

    assert {:ok, deleted} =
             Attachments.usage_projection(query(Attachments, account.tenant.id), subject)

    assert deleted.current == %{ready_retained_count: 0, ready_retained_bytes: 0}
    refute inspect(deleted) =~ "secret-file-name"
    refute inspect(deleted) =~ ready.object_key
  end

  test "room lifecycle overlap is clipped to each UTC day, expiry, and observed time" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    day = Date.add(Date.utc_today(), -2)
    midnight = utc(day)

    audio_call(
      account,
      DateTime.add(midnight, -60),
      DateTime.add(midnight, 180),
      DateTime.add(midnight, 120),
      :audio
    )

    audio_call(
      account,
      DateTime.add(midnight, 86_370),
      DateTime.add(midnight, 86_460),
      DateTime.add(midnight, 86_450),
      :video
    )

    assert {:ok, result} =
             AudioCalls.usage_projection(query(AudioCalls, account.tenant.id, day, day), subject)

    assert hd(result.daily).metrics.observed_room_seconds == 150
    assert hd(result.daily).metrics.started == 1
    assert hd(result.daily).metrics.video_started == 1
    assert hd(result.daily).metrics.audio_started == 0
    assert result.current == %{current_active: 0, current_ending: 0}
  end

  test "telephone durations start at answer and clip to expiry without counting ringing time" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    day = Date.add(Date.utc_today(), -2)
    midnight = utc(day)
    number = number(account)

    phone_call(
      account,
      number,
      DateTime.add(midnight, -60),
      DateTime.add(midnight, 90),
      DateTime.add(midnight, 150),
      DateTime.add(midnight, 120),
      :inbound
    )

    phone_call(
      account,
      number,
      DateTime.add(midnight, 20),
      nil,
      DateTime.add(midnight, 90),
      DateTime.add(midnight, 100),
      :outbound
    )

    assert {:ok, result} =
             Telephony.usage_projection(query(Telephony, account.tenant.id, day, day), subject)

    assert hd(result.daily).metrics.observed_answered_seconds == 30
    assert hd(result.daily).metrics.started == 1
    assert hd(result.daily).metrics.outbound_started == 1
    refute inspect(result) =~ number.phone_number
  end

  test "live call durations stop at the source observation instead of counting future expiry" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    now = DateTime.utc_now() |> Map.update!(:microsecond, fn {_value, _precision} -> {0, 6} end)
    start_at = DateTime.add(now, -30)
    answer_at = DateTime.add(now, -10)
    expires_at = DateTime.add(now, 600)

    Repo.insert!(%AudioCall{
      tenant_id: account.tenant.id,
      conversation_id: account.conversation.id,
      started_by_user_id: account.user.id,
      provider_room: "usage-#{Ecto.UUID.generate()}",
      media_kind: :audio,
      status: :active,
      started_at: start_at,
      expires_at: expires_at
    })

    number = number(account)

    Repo.insert!(%Call{
      tenant_id: account.tenant.id,
      user_id: account.user.id,
      number_id: number.id,
      direction: :outbound,
      status: :answered,
      from_number: number.phone_number,
      to_number: "+14155550200",
      extension: "101",
      inbound_trunk_id: "test-inbound",
      outbound_trunk_id: "test-outbound",
      provider_room: "usage-#{Ecto.UUID.generate()}",
      provider_identity: "usage-#{Ecto.UUID.generate()}",
      started_at: start_at,
      answered_at: answer_at,
      expires_at: expires_at
    })

    assert {:ok, audio} =
             AudioCalls.usage_projection(
               query(AudioCalls, account.tenant.id, DateTime.to_date(start_at), Date.utc_today()),
               subject
             )

    assert audio.current.current_active == 1

    assert Enum.sum(Enum.map(audio.daily, & &1.metrics.observed_room_seconds)) ==
             DateTime.diff(audio.observed_at, start_at, :second)

    assert Enum.sum(Enum.map(audio.daily, & &1.metrics.observed_room_seconds)) < 600

    assert {:ok, phone} =
             Telephony.usage_projection(
               query(Telephony, account.tenant.id, DateTime.to_date(start_at), Date.utc_today()),
               subject
             )

    assert phone.current.current_answered == 1

    assert Enum.sum(Enum.map(phone.daily, & &1.metrics.observed_answered_seconds)) ==
             DateTime.diff(phone.observed_at, answer_at, :second)

    assert Enum.sum(Enum.map(phone.daily, & &1.metrics.observed_answered_seconds)) < 600
  end

  test "final disclosure refuses expired identity after encoding and enforces the binary bound" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    assert {:ok, "{}"} = Accounts.with_usage_report_disclosure(subject, fn -> {:ok, "{}"} end)

    assert {:error, :usage_report_too_large} =
             Accounts.with_usage_report_disclosure(subject, fn ->
               {:ok, String.duplicate("x", 1_048_577)}
             end)

    deadline = DateTime.add(DateTime.utc_now(), 2, :second)

    Repo.update_all(from(s in Session, where: s.id == ^account.session.id),
      set: [expires_at: deadline]
    )

    parent = self()

    assert {:error, :forbidden} =
             Accounts.with_usage_report_disclosure(subject, fn ->
               send(parent, :usage_encoder_entered)

               receive do
               after
                 2_200 -> :ok
               end

               {:ok, "must not be disclosed"}
             end)

    assert_receive :usage_encoder_entered
  end

  defp queries(tenant, from, through),
    do:
      Enum.map(
        [Accounts, Conversations, Messaging, Attachments, AudioCalls, Telephony],
        &{&1, query(&1, tenant, from, through)}
      )

  defp query(owner, tenant, from \\ Date.utc_today(), through \\ Date.utc_today()),
    do: struct(Module.concat(owner, UsageQuery), tenant_id: tenant, from: from, through: through)

  defp utc(day), do: DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")

  defp message(account, time, sequence),
    do:
      Repo.insert!(%Message{
        tenant_id: account.tenant.id,
        conversation_id: account.conversation.id,
        sender_user_id: account.user.id,
        sender_device_id: account.device.id,
        client_message_id: Ecto.UUID.generate(),
        conversation_sequence: sequence,
        body: "sensitive usage body",
        status: :active,
        inserted_at: time
      })

  defp attachment(account, status, size),
    do:
      Repo.insert!(%Attachment{
        tenant_id: account.tenant.id,
        owner_user_id: account.user.id,
        object_key: "usage-#{Ecto.UUID.generate()}",
        file_name: "secret-file-name",
        content_type: "text/plain",
        byte_size: size,
        checksum_sha256: String.duplicate("a", 64),
        status: status,
        scan_status: if(status == :ready, do: :clean, else: :pending),
        object_version_id: if(status == :ready, do: "version-1"),
        object_etag: if(status == :ready, do: "etag-1"),
        verified_checksum_sha256: if(status == :ready, do: String.duplicate("a", 64))
      })

  defp audio_call(account, start_at, expires_at, ended_at, kind),
    do:
      Repo.insert!(%AudioCall{
        tenant_id: account.tenant.id,
        conversation_id: account.conversation.id,
        started_by_user_id: account.user.id,
        provider_room: "usage-#{Ecto.UUID.generate()}",
        media_kind: kind,
        status: :ended,
        started_at: start_at,
        expires_at: expires_at,
        ended_at: ended_at,
        end_reason: "qualification"
      })

  defp number(account),
    do:
      Repo.insert!(%Number{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        phone_number:
          "+1415555#{String.pad_leading(Integer.to_string(rem(System.unique_integer([:positive]), 10000)), 4, "0")}",
        extension: "101",
        inbound_trunk_id: "test-inbound",
        outbound_trunk_id: "test-outbound"
      })

  defp phone_call(account, number, start_at, answer_at, ended_at, expires_at, direction),
    do:
      Repo.insert!(%Call{
        tenant_id: account.tenant.id,
        user_id: account.user.id,
        number_id: number.id,
        direction: direction,
        status: :ended,
        from_number: number.phone_number,
        to_number: "+14155550200",
        extension: "101",
        inbound_trunk_id: "test-inbound",
        outbound_trunk_id: "test-outbound",
        provider_room: "usage-#{Ecto.UUID.generate()}",
        provider_identity: "usage-#{Ecto.UUID.generate()}",
        started_at: start_at,
        answered_at: answer_at,
        ended_at: ended_at,
        expires_at: expires_at,
        end_reason: "qualification"
      })
end
