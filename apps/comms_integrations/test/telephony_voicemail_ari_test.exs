defmodule CommsIntegrations.TelephonyVoicemailARITest do
  use ExUnit.Case, async: false
  alias CommsCore.Telephony.VoicemailRequest
  alias CommsIntegrations.Telephony.AsteriskARI
  @call_id "4acf5490-60ba-439d-8a74-84960a9a1e4d"
  setup do
    values = %{
      telephony_pbx_enabled: true,
      telephony_pbx_qualified: true,
      telephony_pbx_api_url: "https://pbx.example.test",
      telephony_pbx_username: "voice",
      telephony_pbx_password: "synthetic-pbx-password-long-enough",
      telephony_pbx_endpoint: "carrier",
      telephony_pbx_webhook_secret: String.duplicate("s", 32)
    }

    previous =
      Map.new(values, fn {key, _} -> {key, Application.fetch_env(:comms_integrations, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:comms_integrations, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:comms_integrations, key, value)
        {key, :error} -> Application.delete_env(:comms_integrations, key)
      end)
    end)

    :ok
  end

  test "authenticated bounded stored-recording reconciliation confirms exact recording name and WAV duration" do
    request = request()
    body = wav(16_000)

    requester = fn :get, url, headers, "", opts ->
      assert opts[:allowed_hosts] == ["pbx.example.test"] and opts[:allowed_ports] == [443]

      assert List.keyfind(headers, "authorization", 0) ==
               {"authorization",
                "Basic " <> Base.encode64("voice:synthetic-pbx-password-long-enough")}

      if String.ends_with?(url, "/file"),
        do: {:ok, %{status: 200, body: body}},
        else:
          {:ok,
           %{status: 200, body: Jason.encode!(%{name: request.recording_name, format: "wav"})}}
    end

    assert {:ok,
            %{body: ^body, recording_name: name, duration_seconds: 1, content_type: "audio/wav"}} =
             AsteriskARI.recording(request, requester)

    assert name == request.recording_name
  end

  test "a substituted recording, malformed media and oversized audio cannot become available" do
    req = request()

    wrong = fn _, _, _, _, _ ->
      {:ok, %{status: 200, body: Jason.encode!(%{name: "another-recording", format: "wav"})}}
    end

    assert {:error, _} = AsteriskARI.recording(req, wrong)

    Enum.each(["not WAV", wav(121 * 16_000), String.duplicate("a", 8_388_609)], fn bytes ->
      requester = fn _, url, _, _, _ ->
        if String.ends_with?(url, "/file"),
          do: {:ok, %{status: 200, body: bytes}},
          else:
            {:ok, %{status: 200, body: Jason.encode!(%{name: req.recording_name, format: "wav"})}}
      end

      assert {:error, _} = AsteriskARI.recording(req, requester)
    end)
  end

  test "recording deletion tolerates missing live/stored resources without reading another recording" do
    req = %{request() | operation: :delete}

    requester = fn method, url, _, _, _ ->
      assert method in [:delete, :get]
      assert String.ends_with?(url, req.recording_name)
      {:ok, %{status: 404, body: ""}}
    end

    assert :deleted = AsteriskARI.recording(req, requester)
  end

  test "a stopping live source or retained stored file is not falsely confirmed deleted" do
    req = %{request() | operation: :delete}

    Enum.each(["/live/", "/stored/"], fn present ->
      requester = fn method, url, _, _, _ ->
        if method == :get and String.contains?(url, present),
          do:
            {:ok,
             %{status: 200, body: Jason.encode!(%{name: req.recording_name, state: "stopping"})}},
          else: {:ok, %{status: 404, body: ""}}
      end

      assert {:error, :voicemail_source_deletion_pending} = AsteriskARI.recording(req, requester)
    end)
  end

  defp request,
    do: %VoicemailRequest{
      id: Ecto.UUID.generate(),
      tenant_id: Ecto.UUID.generate(),
      call_id: @call_id,
      recording_name: "kc_vm_" <> String.replace(@call_id, "-", ""),
      operation: :reconcile
    }

  defp wav(size),
    do:
      <<"RIFF", 36 + size::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
        8_000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "data", size::little-32,
        0::size(size * 8)>>
end
