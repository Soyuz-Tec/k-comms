defmodule CommsIntegrations.MeetingArtifacts.TranscriptionConfig do
  @moduledoc false

  alias CommsIntegrations.MeetingArtifacts.Config

  def configuration do
    options = Application.get_env(:comms_integrations, :artifact_transcription, [])

    with true <- Keyword.keyword?(options),
         true <- Keyword.get(options, :enabled, false) == true,
         true <- Keyword.get(options, :qualified, false) == true,
         origin when is_binary(origin) <- Keyword.get(options, :origin),
         true <- valid_origin?(origin),
         max_media_bytes <- Keyword.get(options, :max_media_bytes, 26_214_400),
         true <- is_integer(max_media_bytes) and max_media_bytes in 1..26_214_400,
         max_response_bytes <- Keyword.get(options, :max_response_bytes, 1_048_576),
         true <- is_integer(max_response_bytes) and max_response_bytes in 1..1_048_576,
         timeout_ms <- Keyword.get(options, :timeout_ms, 30_000),
         true <- is_integer(timeout_ms) and timeout_ms in 1_000..60_000,
         model <- Keyword.get(options, :model, "whisper-1"),
         true <- is_binary(model) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/, model),
         language <- Keyword.get(options, :language),
         true <-
           is_nil(language) or (is_binary(language) and Regex.match?(~r/^[a-z]{2,3}$/, language)),
         token <- Keyword.get(options, :bearer_token),
         model_sha256 <- Keyword.get(options, :model_sha256),
         true <-
           is_nil(token) or
             (is_binary(token) and byte_size(token) in 32..4_096 and
                not Regex.match?(~r/[\x00-\x20\x7F]/, token)),
         true <-
           is_nil(model_sha256) or
             (is_binary(model_sha256) and Regex.match?(~r/^[a-f0-9]{64}$/, model_sha256) and
                is_binary(token)),
         {:ok, _} <- Config.storage_configuration() do
      {:ok,
       %{
         origin: String.trim_trailing(origin, "/"),
         max_media_bytes: max_media_bytes,
         max_response_bytes: max_response_bytes,
         timeout_ms: timeout_ms,
         model: model,
         language: language,
         bearer_token: token,
         model_sha256: model_sha256
       }}
    else
      _ -> {:error, :artifact_transcription_unavailable}
    end
  end

  defp valid_origin?(origin) do
    uri = URI.parse(origin)

    uri.scheme == "https" and uri.port == 443 and is_binary(uri.host) and uri.host != "" and
      uri.path in [nil, "", "/"] and is_nil(uri.userinfo) and is_nil(uri.query) and
      is_nil(uri.fragment) and not String.ends_with?(String.downcase(uri.host), ".invalid") and
      match?({:error, _}, :inet.parse_address(String.to_charlist(uri.host)))
  rescue
    ArgumentError -> false
  end
end
