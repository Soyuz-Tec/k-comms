defmodule CommsWeb.DirectAudioSignal do
  @moduledoc false

  @max_sdp_bytes 16_384
  @max_candidate_bytes 2_048

  def validate(%{"kind" => kind, "sdp" => sdp} = signal)
      when map_size(signal) == 2 and kind in ["offer", "answer"] and is_binary(sdp) and
             byte_size(sdp) in 1..@max_sdp_bytes do
    if audio_only_sdp?(sdp), do: {:ok, %{kind: kind, sdp: sdp}}, else: {:error, :invalid_signal}
  end

  def validate(%{"kind" => "ice", "candidate" => candidate} = signal)
      when is_binary(candidate) and byte_size(candidate) in 1..@max_candidate_bytes do
    sdp_mid = Map.get(signal, "sdp_mid")
    sdp_mline_index = Map.get(signal, "sdp_mline_index")

    if Enum.all?(Map.keys(signal), &(&1 in ["kind", "candidate", "sdp_mid", "sdp_mline_index"])) and
         (is_nil(sdp_mid) or (is_binary(sdp_mid) and byte_size(sdp_mid) <= 256)) and
         (is_nil(sdp_mline_index) or
            (is_integer(sdp_mline_index) and sdp_mline_index in 0..65_535)) do
      {:ok,
       %{
         kind: "ice",
         candidate: candidate,
         sdp_mid: sdp_mid,
         sdp_mline_index: sdp_mline_index
       }}
    else
      {:error, :invalid_signal}
    end
  end

  def validate(%{"kind" => "media", "enabled" => enabled} = signal)
      when map_size(signal) == 2 and is_boolean(enabled),
      do: {:ok, %{kind: "media", enabled: enabled}}

  def validate(%{"kind" => "fallback"} = signal) when map_size(signal) == 1,
    do: {:ok, %{kind: "fallback"}}

  def validate(_signal), do: {:error, :invalid_signal}

  def audio_only_sdp?(sdp) when is_binary(sdp) do
    lines =
      sdp
      |> String.replace("\r\n", "\n")
      |> String.split("\n", trim: true)

    media_lines = Enum.filter(lines, &String.starts_with?(&1, "m="))

    List.first(lines) == "v=0" and
      match?([_audio], media_lines) and
      Enum.all?(
        media_lines,
        &Regex.match?(~r/^m=audio \d{1,5} UDP\/TLS\/RTP\/SAVPF(?: \d{1,3})+$/, &1)
      ) and
      required_audio_attributes?(lines) and
      not Enum.any?(lines, fn line ->
        String.starts_with?(line, "a=sctp-port:") or
          String.starts_with?(line, "a=sctpmap:") or
          String.contains?(line, <<0>>)
      end)
  end

  def audio_only_sdp?(_sdp), do: false

  defp required_audio_attributes?(lines) do
    Enum.any?(lines, &Regex.match?(~r/^a=ice-ufrag:\S{4,256}$/, &1)) and
      Enum.any?(lines, &Regex.match?(~r/^a=ice-pwd:\S{22,256}$/, &1)) and
      Enum.any?(lines, fn line ->
        Regex.match?(~r/^a=fingerprint:sha-256 (?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$/, line)
      end) and
      Enum.any?(lines, &(&1 in ["a=setup:actpass", "a=setup:active", "a=setup:passive"])) and
      "a=rtcp-mux" in lines
  end
end
