defmodule CommsWeb.CallChannel do
  use CommsWeb, :channel

  alias CommsCore.AudioCalls
  alias CommsWeb.ConversationChannel.AccessPolicy
  alias CommsWeb.{DirectAudio, DirectAudioRateLimit, DirectAudioSignal, Presence}

  @reaction_allowlist ["👍", "👏", "❤️", "😂", "🎉"]
  @collaboration_events [
    "call.hand.v1",
    "call.reaction.v1",
    "call.participant_muted.v1",
    "call.participant_removed.v1"
  ]
  @direct_events ["presence_diff", "call.direct.signal.v1"]
  @direct_peer_limit 2

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
        |> assign(:direct_signal_state, :disabled)
        |> assign(:direct_expected_peer_id, nil)

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
        {:noreply, enforce_direct_peer_limit(socket)}

      {:error, _reason} ->
        {:noreply, disable_direct_audio(socket, true)}
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

  def handle_in("call.direct.disable.v1", %{} = payload, socket)
      when map_size(payload) == 0 do
    case authorize(socket) do
      :ok -> {:reply, :ok, disable_direct_audio(socket, false)}
      _ -> {:stop, :unauthorized, socket}
    end
  end

  def handle_in("call.direct.disable.v1", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_signal"}}, socket}

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
         {:ok, sanitized_signal} <- DirectAudioSignal.validate(signal),
         :ok <- valid_outbound_signal_state(socket, target_peer_id, sanitized_signal),
         :ok <-
           DirectAudioRateLimit.allow_signal?(
             socket.assigns.call_id,
             target_user_id,
             sanitized_signal,
             AccessPolicy.subject(socket)
           ) do
      broadcast_from!(socket, "call.direct.signal.v1", %{
        from_peer_id: socket.assigns.direct_peer_id,
        from_user_id: socket.assigns.user_id,
        target_peer_id: target_peer_id,
        target_user_id: target_user_id,
        signal: sanitized_signal
      })

      socket = transition_after_outbound_signal(socket, target_peer_id, sanitized_signal)
      {:reply, :ok, socket}
    else
      false -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
      {:error, :rate_limited} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
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

  def handle_out(
        "call.direct.signal.v1",
        %{from_peer_id: from_peer_id, target_peer_id: target_peer_id, signal: signal} = payload,
        socket
      ) do
    cond do
      not socket.assigns[:direct_audio] ->
        {:noreply, socket}

      socket.assigns[:direct_peer_id] != target_peer_id ->
        {:noreply, socket}

      true ->
        with :ok <- authorize_direct(socket),
             {:ok, transitioned_socket} <-
               transition_before_inbound_signal(socket, from_peer_id, signal) do
          push(socket, "call.direct.signal.v1", payload)
          {:noreply, transitioned_socket}
        else
          {:error, :unauthorized} ->
            {:stop, :unauthorized, socket}

          _ ->
            {:noreply, socket}
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
    subject = AccessPolicy.subject(socket)

    with :ok <-
           DirectAudio.authorize(
             socket.assigns.call_conversation_id,
             socket.assigns.call_id,
             subject
           ),
         :ok <- DirectAudioRateLimit.allow_join?(socket.assigns.call_id, subject),
         false <- direct_peer_present_for_user?(socket, socket.assigns.user_id) do
      peer_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      socket =
        socket
        |> assign(:direct_audio, true)
        |> assign(:direct_peer_id, peer_id)
        |> assign(:direct_signal_state, :ready)
        |> assign(:direct_expected_peer_id, nil)

      send(self(), :track_direct_audio)

      direct = %{
        enabled: true,
        peer_id: peer_id,
        ice_servers: DirectAudio.ice_servers()
      }

      {Map.put(response, :direct_audio, direct), socket}
    else
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
        socket = enforce_direct_peer_limit(socket)

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
    |> Enum.group_by(& &1.user_id)
    |> Enum.map(fn {_user_id, peers} -> Enum.min_by(peers, & &1.peer_id) end)
    |> Enum.sort_by(& &1.peer_id)
    |> Enum.take(@direct_peer_limit)
  end

  defp target_user(socket, target_peer_id)
       when is_binary(target_peer_id) and byte_size(target_peer_id) == 22 do
    with true <- target_peer_id != socket.assigns.direct_peer_id,
         true <- Enum.any?(direct_peers(socket), &(&1.peer_id == target_peer_id)),
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

  defp valid_outbound_signal_state(socket, target_peer_id, %{kind: "offer"}) do
    if socket.assigns.direct_signal_state == :ready and
         socket.assigns.direct_peer_id < target_peer_id,
       do: :ok,
       else: {:error, :invalid_signal_state}
  end

  defp valid_outbound_signal_state(socket, target_peer_id, %{kind: "answer"}) do
    if socket.assigns.direct_signal_state == :offer_received and
         socket.assigns.direct_expected_peer_id == target_peer_id,
       do: :ok,
       else: {:error, :invalid_signal_state}
  end

  defp valid_outbound_signal_state(socket, target_peer_id, %{kind: "ice"}) do
    if socket.assigns.direct_signal_state in [:offer_sent, :offer_received, :connected] and
         socket.assigns.direct_expected_peer_id == target_peer_id,
       do: :ok,
       else: {:error, :invalid_signal_state}
  end

  defp valid_outbound_signal_state(socket, target_peer_id, %{kind: "media"}) do
    if socket.assigns.direct_signal_state == :connected and
         socket.assigns.direct_expected_peer_id == target_peer_id,
       do: :ok,
       else: {:error, :invalid_signal_state}
  end

  defp valid_outbound_signal_state(socket, target_peer_id, %{kind: "fallback"}) do
    if expected_or_ready_peer?(socket, target_peer_id),
      do: :ok,
      else: {:error, :invalid_signal_state}
  end

  defp transition_after_outbound_signal(socket, target_peer_id, %{kind: "offer"}) do
    socket
    |> assign(:direct_signal_state, :offer_sent)
    |> assign(:direct_expected_peer_id, target_peer_id)
  end

  defp transition_after_outbound_signal(socket, _target_peer_id, %{kind: "answer"}),
    do: assign(socket, :direct_signal_state, :connected)

  defp transition_after_outbound_signal(socket, _target_peer_id, %{kind: "fallback"}),
    do: disable_direct_audio(socket, false)

  defp transition_after_outbound_signal(socket, _target_peer_id, _signal), do: socket

  defp transition_before_inbound_signal(socket, from_peer_id, %{kind: "offer"}) do
    if socket.assigns.direct_signal_state == :ready and
         from_peer_id < socket.assigns.direct_peer_id do
      {:ok,
       socket
       |> assign(:direct_signal_state, :offer_received)
       |> assign(:direct_expected_peer_id, from_peer_id)}
    else
      {:error, :invalid_signal_state}
    end
  end

  defp transition_before_inbound_signal(socket, from_peer_id, %{kind: "answer"}) do
    if socket.assigns.direct_signal_state == :offer_sent and
         socket.assigns.direct_expected_peer_id == from_peer_id,
       do: {:ok, assign(socket, :direct_signal_state, :connected)},
       else: {:error, :invalid_signal_state}
  end

  defp transition_before_inbound_signal(socket, from_peer_id, %{kind: kind})
       when kind in ["ice", "media"] do
    allowed_states =
      if kind == "media", do: [:connected], else: [:offer_sent, :offer_received, :connected]

    if socket.assigns.direct_signal_state in allowed_states and
         socket.assigns.direct_expected_peer_id == from_peer_id,
       do: {:ok, socket},
       else: {:error, :invalid_signal_state}
  end

  defp transition_before_inbound_signal(socket, from_peer_id, %{kind: "fallback"}) do
    if expected_or_ready_peer?(socket, from_peer_id) do
      push(socket, "call.direct.disabled.v1", %{reason: "peer_fallback"})
      {:ok, disable_direct_audio(socket, false)}
    else
      {:error, :invalid_signal_state}
    end
  end

  defp expected_or_ready_peer?(socket, peer_id) do
    socket.assigns.direct_signal_state == :ready or
      (socket.assigns.direct_signal_state in [:offer_sent, :offer_received, :connected] and
         socket.assigns.direct_expected_peer_id == peer_id)
  end

  defp direct_peer_present_for_user?(socket, user_id) do
    socket
    |> Presence.list()
    |> Enum.any?(fn
      {_peer_id, %{metas: metas}} when is_list(metas) ->
        Enum.any?(metas, &(&1[:direct_audio] == true and &1[:user_id] == user_id))

      _ ->
        false
    end)
  end

  defp enforce_direct_peer_limit(%{assigns: %{direct_audio: true}} = socket) do
    retained_peer =
      socket
      |> direct_peers()
      |> Enum.find(&(&1.user_id == socket.assigns.user_id))

    if retained_peer && retained_peer.peer_id == socket.assigns.direct_peer_id do
      socket
    else
      push(socket, "call.direct.disabled.v1", %{reason: "peer_limit"})
      disable_direct_audio(socket, false)
    end
  end

  defp enforce_direct_peer_limit(socket), do: socket

  defp disable_direct_audio(%{assigns: %{direct_audio: true}} = socket, notify_client?) do
    if is_binary(socket.assigns[:direct_peer_id]) do
      Presence.untrack(socket, socket.assigns.direct_peer_id)
    end

    if notify_client?, do: push(socket, "call.direct.disabled.v1", %{reason: "disabled"})

    socket
    |> assign(:direct_audio, false)
    |> assign(:direct_peer_id, nil)
    |> assign(:direct_signal_state, :disabled)
    |> assign(:direct_expected_peer_id, nil)
  end

  defp disable_direct_audio(socket, _notify_client?), do: socket
end
