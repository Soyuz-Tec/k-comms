defmodule CommsWeb.AudioCallController do
  use CommsWeb, :controller

  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.{CallView, CredentialRequest, ProviderCall}
  alias CommsIntegrations.Audio.LiveKitToken
  alias CommsIntegrations.Audio.RoomService
  alias CommsWeb.{Broadcast, Presenter}

  def show(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, call} <- AudioCalls.get_active(conversation_id, conn.assigns.current_subject) do
      json(conn, %{
        data: if(call, do: present_call(call), else: nil)
      })
    end
  end

  def show_audio(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, call} <-
           AudioCalls.get_active(conversation_id, conn.assigns.current_subject, :audio) do
      json(conn, %{
        data: if(call, do: present_call(call), else: nil)
      })
    end
  end

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, media_kind} <- media_kind(params) do
      create_call(conn, conversation_id, media_kind)
    end
  end

  def create_audio(conn, %{"conversation_id" => conversation_id} = params) do
    with :ok <- ensure_legacy_audio(params) do
      create_call(conn, conversation_id, :audio)
    end
  end

  defp create_call(conn, conversation_id, media_kind) do
    subject = conn.assigns.current_subject

    with :ok <- LiveKitToken.ensure_available(),
         {:ok, call, status, credential} <-
           AudioCalls.start_with_join_authorized(
             conversation_id,
             subject,
             media_kind,
             &delete_provider_room/1,
             &issue_credential(&1, conn.assigns.current_user.display_name)
           ) do
      if status == :created do
        broadcast_event(conversation_id, "started", call)
      end

      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> json(%{data: present_call(call), credential: credential})
    end
  end

  def join(conn, %{"conversation_id" => conversation_id, "call_id" => call_id}) do
    join_call(conn, conversation_id, call_id, nil)
  end

  def join_audio(conn, %{"conversation_id" => conversation_id, "call_id" => call_id}) do
    join_call(conn, conversation_id, call_id, :audio)
  end

  defp join_call(conn, conversation_id, call_id, expected_kind) do
    subject = conn.assigns.current_subject

    with :ok <- LiveKitToken.ensure_available(),
         {:ok, call, credential} <-
           AudioCalls.with_join_authorized(
             conversation_id,
             call_id,
             subject,
             expected_kind,
             &issue_credential(&1, conn.assigns.current_user.display_name)
           ) do
      json(conn, %{data: present_call(call), credential: credential})
    end
  end

  def end_call(
        conn,
        %{"conversation_id" => conversation_id, "call_id" => call_id} = params
      ) do
    end_call_with_kind(conn, conversation_id, call_id, params, nil)
  end

  def end_audio(
        conn,
        %{"conversation_id" => conversation_id, "call_id" => call_id} = params
      ) do
    end_call_with_kind(conn, conversation_id, call_id, params, :audio)
  end

  defp end_call_with_kind(conn, conversation_id, call_id, params, expected_kind) do
    subject = conn.assigns.current_subject

    with {:ok, call} <-
           AudioCalls.end_call(
             conversation_id,
             call_id,
             params,
             subject,
             &delete_provider_room/1,
             expected_kind
           ) do
      broadcast_event(conversation_id, "ended", call)
      json(conn, %{data: present_call(call)})
    end
  end

  defp broadcast_event(conversation_id, lifecycle, %CallView{} = call) do
    payload = broadcast_payload(call)
    Broadcast.event(conversation_id, "call.#{lifecycle}.v1", payload)

    if call.media_kind == :audio do
      Broadcast.event(conversation_id, "audio_call.#{lifecycle}.v1", payload)
    end
  end

  defp broadcast_payload(call) do
    call
    |> Presenter.audio_call()
    |> Map.take([
      :id,
      :conversation_id,
      :media_kind,
      :started_by_user_id,
      :status,
      :started_at,
      :expires_at,
      :ended_by_user_id,
      :ended_at,
      :end_reason
    ])
  end

  defp present_call(%CallView{} = call), do: Presenter.audio_call(call)

  defp delete_provider_room(%ProviderCall{provider_room: provider_room}),
    do: RoomService.delete_room(provider_room)

  defp issue_credential(
         %CredentialRequest{
           provider_room: provider_room,
           media_kind: media_kind,
           provider_identity: provider_identity
         },
         display_name
       ) do
    LiveKitToken.issue(provider_room, media_kind, provider_identity, display_name)
  end

  defp media_kind(params) do
    case Map.get(params, "media_kind") || Map.get(params, :media_kind) do
      media_kind when media_kind in ["audio", :audio] -> {:ok, :audio}
      media_kind when media_kind in ["video", :video] -> {:ok, :video}
      _ -> {:error, :invalid_media_kind}
    end
  end

  defp ensure_legacy_audio(params) do
    case Map.get(params, "media_kind") || Map.get(params, :media_kind) do
      nil -> :ok
      media_kind when media_kind in ["audio", :audio] -> :ok
      _ -> {:error, :invalid_media_kind}
    end
  end
end
