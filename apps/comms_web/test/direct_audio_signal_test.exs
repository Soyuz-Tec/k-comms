defmodule CommsWeb.DirectAudioSignalTest do
  use ExUnit.Case, async: true

  alias CommsWeb.DirectAudioSignal

  @audio_sdp "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=ice-ufrag:abcd\r\na=ice-pwd:abcdefghijklmnopqrstuv\r\na=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00\r\na=setup:actpass\r\na=rtcp-mux\r\n"

  test "accepts exactly one audio media section" do
    assert {:ok, %{kind: "offer", sdp: @audio_sdp}} =
             DirectAudioSignal.validate(%{"kind" => "offer", "sdp" => @audio_sdp})
  end

  test "rejects video, application, multiple media sections, and SCTP" do
    invalid_descriptions = [
      "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n",
      "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n",
      @audio_sdp <> "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n",
      @audio_sdp <> "a=sctp-port:5000\r\n"
    ]

    for sdp <- invalid_descriptions do
      assert {:error, :invalid_signal} =
               DirectAudioSignal.validate(%{"kind" => "offer", "sdp" => sdp})
    end
  end

  test "rejects audio SDP without the required ICE and DTLS attributes" do
    assert {:error, :invalid_signal} =
             DirectAudioSignal.validate(%{
               "kind" => "offer",
               "sdp" => "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
             })
  end
end
