defmodule CommsWeb.DocumentChannel do
  use CommsWeb, :channel
  alias CommsCore.SharedDocuments
  alias CommsWeb.ConversationChannel.AccessPolicy
  intercept(["document.operation_applied.v1", "document.presence.v1"])

  @impl true
  def join("document:" <> id, _params, socket) do
    case SharedDocuments.authorize(id, AccessPolicy.subject(socket)) do
      {:ok, :ok} -> {:ok, assign(socket, :shared_document_id, id)}
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in(
        "document.presence.v1",
        %{"generation" => generation, "anchor_id" => anchor, "head_id" => head},
        socket
      )
      when is_integer(generation) and generation >= 1 do
    with {:ok, document} <-
           SharedDocuments.get(socket.assigns.shared_document_id, AccessPolicy.subject(socket)),
         true <- generation == document.generation,
         true <- valid_anchor?(anchor, document.atoms) and valid_anchor?(head, document.atoms),
         true <-
           CommsWeb.RateLimiter.allow?({:document_presence, socket.assigns.session_id}, 20, 1) do
      broadcast_from!(socket, "document.presence.v1", %{
        user_id: socket.assigns.user_id,
        device_id: socket.assigns.device_id,
        generation: generation,
        anchor_id: anchor,
        head_id: head
      })

      {:noreply, socket}
    else
      false -> {:noreply, socket}
      _ -> {:stop, :unauthorized, socket}
    end
  end

  def handle_in("document.presence.v1", _, socket), do: {:noreply, socket}
  @impl true
  def handle_out(event, payload, socket)
      when event in ["document.operation_applied.v1", "document.presence.v1"] do
    case SharedDocuments.authorize(
           socket.assigns.shared_document_id,
           AccessPolicy.subject(socket)
         ) do
      {:ok, :ok} ->
        push(socket, event, payload)
        {:noreply, socket}

      _ ->
        {:stop, :unauthorized, socket}
    end
  end

  defp valid_anchor?(nil, _), do: true
  defp valid_anchor?(id, atoms) when is_binary(id), do: Enum.any?(atoms, &(&1.id == id))
  defp valid_anchor?(_, _), do: false
end
