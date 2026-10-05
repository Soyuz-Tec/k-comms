defmodule CommsCore.TelephonyRoutingTest.Provider do
  @behaviour CommsCore.Telephony.ProviderControlPort.Contract
  def capabilities(),
    do: %{queues: %{supported: true, reason: nil}, shared_lines: %{supported: true, reason: nil}}

  def authorize_destination(_), do: {:error, :telephony_destination_forbidden}
  def verify_event(_, _), do: {:error, :invalid_provider_webhook}
  def cleanup_call(_), do: {:error, :telephony_provider_unavailable}
  def bound_call_status(_), do: {:error, :telephony_provider_unavailable}

  def execute_control(%{action: :queue_waiting, call_id: id}) do
    send(self(), {:queue_hold_effect, id})
    {:ok, :submitted}
  end

  def execute_control(_), do: {:error, :telephony_control_unsupported}
end

defmodule CommsCore.TelephonyRoutingTest do
  use CommsCore.DataCase, async: false
  @moduletag :integration
  @moduletag :call
  alias CommsCore.{Accounts, Administration, Telephony}
  alias CommsCore.Telephony.{Call, CredentialRequest, Route}
  alias CommsIntegrations.Telephony.LiveKit
  alias CommsTestSupport.Fixtures
  alias CommsWorkers.TelephonyRoutingWorker

  setup do
    previous = Application.fetch_env(:comms_core, :telephony_control_adapter)

    Application.put_env(
      :comms_core,
      :telephony_control_adapter,
      CommsCore.TelephonyRoutingTest.Provider
    )

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:comms_core, :telephony_control_adapter, v)
        :error -> Application.delete_env(:comms_core, :telephony_control_adapter)
      end
    end)

    :ok
  end

  test "shared line advertises effective assignment and incoming offer to both actual subjects; first device wins" do
    {account, owner, member, member_subject} = ready()
    assert {:ok, route} = Telephony.save_route(route_input([account.user.id, member.id]), owner)
    assert route.mode == :shared_line
    assert {:ok, %{configured: true, number: number}} = Telephony.config(member_subject)
    assert number.phone_number == "+14155550100"
    refute Map.has_key?(number, :inbound_trunk_id)
    assert {:ok, call, :applied} = Telephony.callback(incoming("shared"), LiveKit)
    assert {:ok, %{calls: [owner_offer]}} = Telephony.list_calls(owner, %{scope: "active"})

    assert {:ok, %{calls: [member_offer]}} =
             Telephony.list_calls(member_subject, %{scope: "active"})

    assert owner_offer.can_answer and member_offer.can_answer
    assert {:ok, won, %{issued: true}} = Telephony.answer(call.id, member_subject, issuer())
    assert won.active_on_this_device
    assert Repo.get!(Call, call.id).user_id == member.id
    assert {:error, :not_found} = Telephony.answer(call.id, owner, issuer())
    assert {:ok, %{calls: []}} = Telephony.list_calls(owner, %{scope: "active"})

    assert {:error, :answered_elsewhere} =
             Telephony.answer(call.id, second_member_device(account, member), issuer())
  end

  test "a disabled default DID assignee cannot suppress an enabled route to an active member" do
    {account, owner, member, member_subject} = ready()
    assert {:ok, _} = Telephony.save_route(route_input([member.id]), owner)
    account.user |> Ecto.Changeset.change(status: :suspended) |> Repo.update!()
    assert {:ok, call, :applied} = Telephony.callback(incoming("revoked-default"), LiveKit)
    assert Repo.get!(Call, call.id).offered_user_ids == [member.id]
    assert {:ok, %{calls: [offer]}} = Telephony.list_calls(member_subject, %{scope: "active"})
    assert offer.can_answer
    assert {:ok, won, _} = Telephony.answer(call.id, member_subject, issuer())
    assert won.active_on_this_device
  end

  test "DND recipients are not offered and DND entered while ringing blocks credential admission" do
    {account, owner, member, member_subject} = ready()
    assert {:ok, _} = Telephony.save_route(route_input([account.user.id, member.id]), owner)
    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, member_subject)
    assert {:ok, call, :applied} = Telephony.callback(incoming("dnd"), LiveKit)
    assert Repo.get!(Call, call.id).offered_user_ids == [account.user.id]
    assert {:ok, %{calls: []}} = Telephony.list_calls(member_subject, %{scope: "active"})
    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, owner)
    assert {:ok, visible} = Telephony.get_call(call.id, owner)
    refute visible.can_answer
    assert {:error, :recipient_unavailable} = Telephony.answer(call.id, owner, issuer())
  end

  test "queue capacity and deadlines are bounded and routing re-evaluates live DND before assignment" do
    {account, owner, member, member_subject} = ready()

    assert {:ok, _} =
             Telephony.save_route(
               %{
                 route_input([account.user.id, member.id])
                 | mode: "queue",
                   policy: "round_robin",
                   max_waiting: 1
               },
               owner
             )

    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, owner)
    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, member_subject)
    assert {:ok, call, :applied} = Telephony.callback(incoming("queue"), LiveKit)
    stored = Repo.get!(Call, call.id)
    assert stored.routing_status == "waiting"
    assert {:ok, %{calls: []}} = Telephony.list_calls(owner, %{scope: "active"})
    assert {:ok, {:wait, 5}} = Telephony.advance_route(call.id, TelephonyRoutingWorker)
    assert {:ok, overflow, :ignored} = Telephony.callback(incoming("overflow"), LiveKit)
    assert overflow.status == :failed
    assert {:ok, _} = Accounts.update_availability(%{presence_state: "available"}, member_subject)

    assert {:ok, {:offered, "+14155550100"}} =
             Telephony.advance_route(call.id, TelephonyRoutingWorker)

    assert {:ok, %{calls: [offer]}} = Telephony.list_calls(member_subject, %{scope: "active"})
    assert offer.can_answer
    assert {:error, :forbidden} = Telephony.advance_route(call.id, __MODULE__)
  end

  test "queue media effects run under current routing state and never after its deadline or terminal expiry" do
    {account, owner, member, member_subject} = ready()

    assert {:ok, _} =
             Telephony.save_route(
               %{
                 route_input([account.user.id, member.id])
                 | mode: "queue",
                   policy: "round_robin"
               },
               owner
             )

    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, owner)
    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, member_subject)
    assert {:ok, call, :applied} = Telephony.callback(incoming("fenced-queue"), LiveKit)
    assert {:ok, {:wait, 5}} = Telephony.advance_route(call.id, TelephonyRoutingWorker)
    assert_received {:queue_hold_effect, _}

    Repo.get!(Call, call.id)
    |> Call.changeset(%{route_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})
    |> Repo.update!()

    assert {:ok, :expired} = Telephony.advance_route(call.id, TelephonyRoutingWorker)
    refute_received {:queue_hold_effect, _}
    assert {:ok, _} = Telephony.expire_route(call.id, TelephonyRoutingWorker)
    assert {:ok, :complete} = Telephony.advance_route(call.id, TelephonyRoutingWorker)
    refute_received {:queue_hold_effect, _}
  end

  test "voice policy disabled after queue admission blocks MOH and agent offers" do
    {account, owner, member, member_subject} = ready()

    assert {:ok, _} =
             Telephony.save_route(
               %{
                 route_input([account.user.id, member.id])
                 | mode: "queue",
                   policy: "round_robin"
               },
               owner
             )

    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, owner)
    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, member_subject)
    assert {:ok, call, :applied} = Telephony.callback(incoming("voice-policy"), LiveKit)

    assert {:ok, _} =
             Administration.update_tenant_settings(
               %{allow_audio_calls: false, reason: "Disable queued voice admission", version: 1},
               owner
             )

    assert {:ok, :complete} = Telephony.advance_route(call.id, TelephonyRoutingWorker)
    refute_received {:queue_hold_effect, _}
    assert Repo.get!(Call, call.id).status == :ended
    assert Repo.get!(Call, call.id).end_reason == "tenant_audio_disabled"
    assert :ok = TelephonyRoutingWorker.perform(%Oban.Job{args: %{"call_id" => call.id}})
    assert Repo.get!(Call, call.id).status == :ended
    refute_received {:queue_hold_effect, _}
  end

  test "a retained waiting queue checks current disabled voice policy before provider effects" do
    {account, owner, member, member_subject} = ready()

    assert {:ok, _} =
             Telephony.save_route(
               %{
                 route_input([account.user.id, member.id])
                 | mode: "queue",
                   policy: "round_robin"
               },
               owner
             )

    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, owner)
    assert {:ok, _} = Accounts.update_availability(%{presence_state: "dnd"}, member_subject)
    assert {:ok, call, :applied} = Telephony.callback(incoming("retained-voice-policy"), LiveKit)

    # Represent a retained queue from recovery without relying on the normal
    # administration command's separate active-call termination side effect.
    (Repo.get_by(CommsCore.Administration.TenantSettings, tenant_id: account.tenant.id) ||
       %CommsCore.Administration.TenantSettings{tenant_id: account.tenant.id})
    |> CommsCore.Administration.TenantSettings.changeset(%{allow_audio_calls: false})
    |> Repo.insert_or_update!()

    assert {:ok, :unavailable} = Telephony.advance_route(call.id, TelephonyRoutingWorker)
    refute_received {:queue_hold_effect, _}
    assert Repo.get!(Call, call.id).routing_status == "waiting"
    assert :ok = TelephonyRoutingWorker.perform(%Oban.Job{args: %{"call_id" => call.id}})
    assert Repo.get!(Call, call.id).status == :no_answer
    refute_received {:queue_hold_effect, _}
  end

  test "route edits require step-up, current tenant members, matching version and qualified provider" do
    {account, owner, member, _} = ready()
    foreign = Fixtures.account_fixture()
    assert {:error, :forbidden} = Telephony.save_route(route_input([foreign.user.id]), owner)
    assert {:ok, route} = Telephony.save_route(route_input([account.user.id, member.id]), owner)
    assert {:error, :stale_version} = Telephony.save_route(route_input([account.user.id]), owner)
    Application.delete_env(:comms_core, :telephony_control_adapter)

    assert {:error, :telephony_control_unsupported} =
             Telephony.save_route(
               Map.put(route_input([account.user.id]), :version, route.version),
               owner
             )

    assert Repo.aggregate(Route, :count) == 1
  end

  defp ready do
    account = Fixtures.account_fixture()
    owner = Fixtures.step_up(account)

    assert {:ok, _} =
             Telephony.provision(
               %{
                 phone_number: "+14155550100",
                 extension: "101",
                 user_id: account.user.id,
                 inbound_trunk_id: "ST_inbound",
                 outbound_trunk_id: "ST_outbound",
                 reason: "Synthetic provision"
               },
               owner
             )

    %{user: member} =
      Fixtures.user_fixture(account, %{
        password_hash: CommsCore.Security.Password.hash("synthetic-member-password-long")
      })

    {:ok, auth} =
      Accounts.authenticate_view(
        account.tenant.slug,
        member.email,
        "synthetic-member-password-long",
        %{name: "Member browser", platform: "test"}
      )

    {:ok, context} = Accounts.access_context(auth.session_id)
    {account, owner, member, context.subject}
  end

  defp second_member_device(account, member) do
    {:ok, auth} =
      Accounts.authenticate_view(
        account.tenant.slug,
        member.email,
        "synthetic-member-password-long",
        %{name: "Second member browser", platform: "test"}
      )

    {:ok, context} = Accounts.access_context(auth.session_id)
    context.subject
  end

  defp route_input(ids),
    do: %{
      name: "Shared support",
      mode: "shared_line",
      policy: "simultaneous",
      member_ids: ids,
      max_waiting: 20,
      max_wait_seconds: 120,
      enabled: true,
      reason: "Synthetic route policy"
    }

  defp incoming(suffix),
    do: %{
      event_id: "incoming-" <> suffix,
      event_type: "participant_joined",
      room: "kc_tel_inbound_" <> suffix,
      participant_identity: "sip-" <> suffix,
      participant_kind: :sip,
      participant_sid: "PA-" <> suffix,
      provider_call_id: "SC-" <> suffix,
      trunk_id: "ST_inbound",
      from_number: "+14155550200",
      to_number: "+14155550100"
    }

  defp issuer, do: fn %CredentialRequest{} -> {:ok, %{issued: true}} end
end
