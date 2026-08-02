defmodule CommsWeb.CallChannel do
  use CommsWeb, :channel

  alias CommsCore.AudioCalls
  alias CommsWeb.ConversationChannel.AccessPolicy

  @reaction_allowlist ["👍", "👏", "❤️", "😂", "🎉"]
  @outbound_events [
    "call.hand.v1",
    "call.reaction.v1",
    "call.participant_muted.v1",
    "call.participant_removed.v1"
  ]

  intercept(@outbound_events)

  @impl true
  def join("call:" <> call_id, %{"conversation_id" => conversation_id}, socket) do
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

      {:ok, response, socket}
    else
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid_join"}}

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

  @impl true
  def handle_out(event, payload, socket) when event in @outbound_events do
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
end
