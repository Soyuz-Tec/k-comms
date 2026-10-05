defmodule CommsWeb.TelephonyIvrControllerTest.ControlProvider do
  @behaviour CommsCore.Telephony.ProviderControlPort.Contract
  def capabilities, do: %{queues: %{supported: true}, shared_lines: %{supported: true}}
  def authorize_destination(_), do: {:error, :telephony_destination_forbidden}
  def execute_control(_), do: {:error, :telephony_control_unsupported}
  def verify_event(_, _), do: {:error, :invalid_provider_webhook}
  def cleanup_call(_), do: {:error, :telephony_provider_unavailable}
  def bound_call_status(_), do: {:error, :telephony_provider_unavailable}
end

defmodule CommsWeb.TelephonyIvrControllerTest do
  use CommsWeb.ConnCase, async: false
  import Ecto.Query
  @moduletag :integration
  @moduletag :call
  alias CommsCore.{Repo, Telephony}
  alias CommsCore.Accounts.Session
  alias CommsTestSupport.Fixtures
  @secret String.duplicate("s", 32)

  setup do
    values = [
      {:comms_core, :telephony_ivr_adapter, CommsIntegrations.Telephony.IvrARI},
      {:comms_core, :telephony_control_adapter,
       CommsWeb.TelephonyIvrControllerTest.ControlProvider},
      {:comms_integrations, :telephony_ivr_qualified, false},
      {:comms_integrations, :telephony_ivr_prompt_allowlist, ["sound:custom/menu"]},
      {:comms_integrations, :telephony_pbx_webhook_secret, @secret}
    ]

    previous =
      Enum.map(values, fn {app, key, _} -> {app, key, Application.fetch_env(app, key)} end)

    Enum.each(values, fn {app, key, value} -> Application.put_env(app, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    account = Fixtures.account_fixture()

    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    {:ok, account: account, token: token}
  end

  test "implemented menu, own-state and supervisor paths require current human authentication" do
    for path <- [
          "/api/v1/admin/telephony/ivr",
          "/api/v1/telephony/agent-state",
          "/api/v1/admin/telephony/queues/current"
        ] do
      assert build_conn() |> get(path) |> json_response(401)
    end

    assert build_conn() |> put("/api/v1/admin/telephony/ivr", menu()) |> json_response(401)

    assert build_conn()
           |> put("/api/v1/telephony/agent-state", %{
             state: "away",
             duration_seconds: 300,
             version: 0
           })
           |> json_response(401)
  end

  test "unqualified menus stay closed, read is no-store, and saves require verified saved versions",
       %{account: account, token: token} do
    provision(account)
    clear_step_up(account)
    conn = authenticated(token) |> get("/api/v1/admin/telephony/ivr")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    config = conn |> json_response(200) |> fixture("configuration")
    assert config["data"]["available"] == false
    assert config["data"]["menu"] == nil

    assert authenticated(token)
           |> put("/api/v1/admin/telephony/ivr", menu())
           |> json_response(428)

    Fixtures.step_up(account)

    saved =
      authenticated(token)
      |> put("/api/v1/admin/telephony/ivr", menu())
      |> json_response(200)
      |> fixture("menu")

    assert saved["data"]["version"] == 1
    assert saved["data"]["enabled"] == false

    assert authenticated(token)
           |> put("/api/v1/admin/telephony/ivr", menu())
           |> json_response(409)
           |> get_in(["error", "code"]) == "stale_version"

    assert authenticated(token)
           |> put("/api/v1/admin/telephony/ivr", %{menu() | enabled: true, version: 1})
           |> json_response(503)
           |> get_in(["error", "code"]) == "telephony_ivr_unavailable"
  end

  test "own queue disposition is member-scoped while aggregate snapshot requires verification", %{
    account: account,
    token: token
  } do
    provision(account)

    assert authenticated(token)
           |> get("/api/v1/telephony/agent-state")
           |> json_response(403)
           |> get_in(["error", "code"]) == "telephony_agent_not_assigned"

    assert {:ok, _} =
             Telephony.save_route(
               %{
                 name: "Support",
                 mode: "queue",
                 policy: "round_robin",
                 member_ids: [account.user.id],
                 max_waiting: 10,
                 max_wait_seconds: 60,
                 enabled: true,
                 reason: "Synthetic route"
               },
               Fixtures.subject(account)
             )

    clear_step_up(account)

    state =
      authenticated(token)
      |> put("/api/v1/telephony/agent-state", %{
        state: "wrap_up",
        duration_seconds: 300,
        version: 0
      })
      |> json_response(200)
      |> fixture("agent-state")

    assert state["data"]["state"] == "wrap_up"
    assert state["data"]["version"] == 1
    assert state["data"]["online_presence_observed"] == false

    assert authenticated(token)
           |> get("/api/v1/admin/telephony/queues/current")
           |> json_response(428)

    Fixtures.step_up(account)
    conn = authenticated(token) |> get("/api/v1/admin/telephony/queues/current")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    snapshot = conn |> json_response(200) |> fixture("queue-snapshot")
    assert snapshot["data"]["coverage"] == "current_retained_calls"
    assert snapshot["data"]["online_presence_observed"] == false
    assert snapshot["data"]["historical_service_level_available"] == false

    assert [%{"waiting_calls" => 0, "offered_calls" => 0, "answered_calls" => 0}] =
             snapshot["data"]["routes"]
  end

  test "provider path accepts only exact-body signatures and neutrally acknowledges an absent run" do
    event = %{
      type: "PlaybackFinished",
      event_id: String.duplicate("a", 64),
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      playback: %{
        id: "kc_ivr_92df0e80041f48888b856d5eae265aff_1",
        state: "done",
        target_uri: "channel:external",
        media_uri: "sound:custom/menu"
      }
    }

    body = Jason.encode!(event)
    authorization = signed(body)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", authorization)

    assert conn |> post("/api/v1/telephony/ivr/webhook", body) |> json_response(200) == %{
             "data" => %{"accepted" => true}
           }

    bad =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", authorization)

    assert bad |> post("/api/v1/telephony/ivr/webhook", body <> " ") |> json_response(401)
  end

  defp provision(account) do
    Fixtures.step_up(account)

    assert {:ok, _} =
             Telephony.provision(
               %{
                 phone_number: "+14155550100",
                 extension: "101",
                 user_id: account.user.id,
                 inbound_trunk_id: "ST_inbound",
                 outbound_trunk_id: "ST_outbound",
                 reason: "Synthetic IVR line"
               },
               Fixtures.subject(account)
             )
  end

  defp clear_step_up(account),
    do:
      Repo.update_all(from(s in Session, where: s.id == ^account.session.id),
        set: [step_up_at: nil]
      )

  defp authenticated(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  defp menu,
    do: %{
      name: "Support",
      prompt_media: "sound:custom/menu",
      choices: %{"1" => %{"kind" => "hangup"}},
      fallback: %{"kind" => "hangup"},
      digit_timeout_seconds: 10,
      max_retries: 1,
      enabled: false,
      version: 0,
      reason: "Synthetic disabled menu"
    }

  defp signed(body) do
    timestamp = Integer.to_string(System.system_time(:second))

    signature =
      :crypto.mac(:hmac, :sha256, @secret, timestamp <> "." <> body)
      |> Base.encode16(case: :lower)

    "v1:" <> timestamp <> ":" <> signature
  end

  defp fixture(response, name) do
    if directory = System.get_env("IVR_SCHEMA_FIXTURES_DIR") do
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o700)
      path = Path.join(directory, name <> ".json")
      File.write!(path, Jason.encode!(response, pretty: true))
      File.chmod!(path, 0o600)
    end

    response
  end
end
