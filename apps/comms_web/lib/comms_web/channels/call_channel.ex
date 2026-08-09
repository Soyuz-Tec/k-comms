defmodule CommsWeb.CallChannel do
  use CommsWeb, :channel

  alias CommsCore.AudioCalls
  alias CommsWeb.ConversationChannel.AccessPolicy
  alias CommsWeb.{DirectAudio, Presence}

  @reaction_allowlist ["👍", "👏", "❤️", "😂", "🎉"]
  @collaboration_events [
    "call.hand.v1",
    "call.reaction.v1",
    "call.participant_muted.v1",
    "call.participant_removed.v1"
  ]
  @direct_events ["presence_diff", "call.direct.peers.v1", "call.direct.signal.v1"]

  intercept(@collaboration_events ++ @direct_events)

  @impl true
  def join("call:" <> call_id, %{"conversation_id" => conversation_id} = payload, socket) do
    subject = AccessPolicy.subject(socket)

    with :ok <- AccessPolicy.conversation_allowed(socket, conversation_id),
         :ok <- AudioCalls.authorize_participant(conversation_id, call_id, subject),
         {:ok, participants} <- AudioCalls.list_participants(conversation_id, call_id, subject) do
      response = %{
        raised_user_ids:
          participants
          |> Enum.filter(& &1.hand_raised)
          |> Enum.map(& &1.user_id)
      }

      socket =
        socket
        |> assign(:call_id, call_id)
        |> assign(:call_conversation_id, conversation_id)
        |> assign(:direct_audio, false)

      {response, socket} = enable_direct_audio(response, socket, payload)

      {:ok, response, socket}
    else
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid_join"}}

  @impl true
  def handle_info(:track_direct_audio, socket) do
    case Presence.track(socket, socket.assigns.direct_peer_id, %{
           direct_audio: true,
           user_id: socket.assigns.user_id,
           online_at: System.system_time(:second)
         }) do
      {:ok, _ref} ->
        broadcast!(socket, "call.direct.peers.v1", %{})
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, assign(socket, :direct_audio, false)}
    end
  end

  @impl true
  def handle_in("call.hand.set.v1", %{"raised" => raised}, socket) when is_boolean(raised) do
    with :ok <- authorize(socket),
         {:ok, participant} <-
           AudioCalls.set_hand(
             socket.assigns.call_conversation_id,
             socket.assigns.call_id,
             raised,
             AccessPolicy.subject(socket)
           ) do
      broadcast!(socket, "call.hand.v1", %{
        user_id: participant.user_id,
        raised: participant.hand_raised,
        raised_at: participant.hand_raised_at
      })

      {:reply, {:ok, %{raised: participant.hand_raised}}, socket}
    else
      _ -> {:stop, :unauthorized, socket}
    end
  end

  def handle_in("call.hand.set.v1", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_signal"}}, socket}

  def handle_in("call.reaction.v1", %{"emoji" => emoji}, socket)
      when emoji in @reaction_allowlist do
    with :ok <- authorize(socket),
         true <- CommsWeb.RateLimiter.allow?({:call_reaction, socket.assigns.session_id}, 4, 5) do
      broadcast!(socket, "call.reaction.v1", %{
        user_id: socket.assigns.user_id,
        emoji: emoji,
        occurred_at: DateTime.utc_now()
      })

      {:reply, :ok, socket}
    else
      false -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
      _ -> {:stop, :unauthorized, socket}
    end
  end

  def handle_in("call.reaction.v1", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_reaction"}}, socket}

  def handle_in(
        "call.direct.signal.v1",
        %{"target_peer_id" => target_peer_id, "signal" => signal},
        socket
      ) do
    with :ok <- authorize_direct(socket),
         true <-
           CommsWeb.RateLimiter.allow?(
             {:call_direct_signal, socket.assigns.session_id, socket.assigns.call_id},
             240,
             60
           ),
         {:ok, target_user_id} <- target_user(socket, target_peer_id),
         {:ok, sanitized_signal} <- valid_signal(signal) do
      broadcast_from!(socket, "call.direct.signal.v1", %{
        from_peer_id: socket.assigns.direct_peer_id,
        from_user_id: socket.assigns.user_id,
        target_peer_id: target_peer_id,
        target_user_id: target_user_id,
        signal: sanitized_signal
      })

      {:reply, :ok, socket}
    else
      false -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
      {:error, :unauthorized} -> {:stop, :unauthorized, socket}
      _ -> {:reply, {:error, %{reason: "invalid_signal"}}, socket}
    end
  end

  def handle_in("call.direct.signal.v1", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_signal"}}, socket}

  @impl true
  def handle_out("presence_diff", _payload, socket) do
    deliver_direct_peers(socket)
  end

  def handle_out("call.direct.peers.v1", _payload, socket) do
    deliver_direct_peers(socket)
  end

  def handle_out(
        "call.direct.signal.v1",
        %{target_peer_id: target_peer_id} = payload,
        socket
      ) do
    cond do
      not socket.assigns[:direct_audio] ->
        {:noreply, socket}

      socket.assigns[:direct_peer_id] != target_peer_id ->
        {:noreply, socket}

      true ->
        case authorize_direct(socket) do
          :ok ->
            push(socket, "call.direct.signal.v1", payload)
            {:noreply, socket}

          _ ->
            {:stop, :unauthorized, socket}
        end
    end
  end

  def handle_out(event, payload, socket) when event in @collaboration_events do
    case authorize(socket) do
      :ok ->
        push(socket, event, payload)
        {:noreply, socket}

      _ ->
        {:stop, :unauthorized, socket}
    end
  end

  defp authorize(socket) do
    conversation_id = socket.assigns.call_conversation_id

    with :ok <- AccessPolicy.conversation_allowed(socket, conversation_id),
         :ok <-
           AudioCalls.authorize_participant(
             conversation_id,
             socket.assigns.call_id,
             AccessPolicy.subject(socket)
           ) do
      :ok
    end
  end

  defp enable_direct_audio(response, socket, %{"direct_audio" => true}) do
    case DirectAudio.authorize(
           socket.assigns.call_conversation_id,
           socket.assigns.call_id,
           AccessPolicy.subject(socket)
         ) do
      :ok ->
        peer_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

        socket =
          socket
          |> assign(:direct_audio, true)
          |> assign(:direct_peer_id, peer_id)

        send(self(), :track_direct_audio)

        direct = %{
          enabled: true,
          peer_id: peer_id,
          ice_servers: DirectAudio.ice_servers()
        }

        {Map.put(response, :direct_audio, direct), socket}

      _ ->
        {Map.put(response, :direct_audio, %{enabled: false}), socket}
    end
  end

  defp enable_direct_audio(response, socket, _payload),
    do: {Map.put(response, :direct_audio, %{enabled: false}), socket}

  defp authorize_direct(socket) do
    if socket.assigns[:direct_audio] do
      case DirectAudio.authorize(
             socket.assigns.call_conversation_id,
             socket.assigns.call_id,
             AccessPolicy.subject(socket)
           ) do
        :ok -> :ok
        _ -> {:error, :unauthorized}
      end
    else
      {:error, :direct_audio_unavailable}
    end
  end

  defp deliver_direct_peers(socket) do
    case authorize(socket) do
      :ok ->
        if socket.assigns[:direct_audio] do
          push(socket, "call.direct.peers.v1", %{peers: direct_peers(socket)})
        end

        {:noreply, socket}

      _ ->
        {:stop, :unauthorized, socket}
    end
  end

  defp direct_peers(socket) do
    socket
    |> Presence.list()
    |> Enum.flat_map(fn
      {peer_id, %{metas: metas}} when is_binary(peer_id) and is_list(metas) ->
        metas
        |> Enum.filter(&(&1[:direct_audio] == true and is_binary(&1[:user_id])))
        |> Enum.map(&%{peer_id: peer_id, user_id: &1.user_id})

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.peer_id)
    |> Enum.sort_by(& &1.peer_id)
  end

  defp target_user(socket, target_peer_id)
       when is_binary(target_peer_id) and byte_size(target_peer_id) == 22 do
    with true <- target_peer_id != socket.assigns.direct_peer_id,
         %{metas: metas} <- Presence.list(socket)[target_peer_id],
         %{user_id: target_user_id} <-
           Enum.find(metas, &(&1[:direct_audio] == true and is_binary(&1[:user_id]))),
         true <- target_user_id != socket.assigns.user_id do
      {:ok, target_user_id}
    else
      _ -> {:error, :target_unavailable}
    end
  end

  defp target_user(_socket, _target_peer_id), do: {:error, :target_unavailable}

  defp valid_signal(%{"kind" => kind, "sdp" => sdp} = signal)
       when map_size(signal) == 2 and kind in ["offer", "answer"] and is_binary(sdp) and
              byte_size(sdp) in 1..16_384,
       do: {:ok, %{kind: kind, sdp: sdp}}

  defp valid_signal(
         %{
           "kind" => "ice",
           "candidate" => candidate
         } = signal
       )
       when is_binary(candidate) and byte_size(candidate) in 1..2_048 do
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

  defp valid_signal(%{"kind" => "media", "enabled" => enabled} = signal)
       when map_size(signal) == 2 and is_boolean(enabled),
       do: {:ok, %{kind: "media", enabled: enabled}}

  defp valid_signal(%{"kind" => "fallback"} = signal) when map_size(signal) == 1,
    do: {:ok, %{kind: "fallback"}}

  defp valid_signal(_signal), do: {:error, :invalid_signal}
end
