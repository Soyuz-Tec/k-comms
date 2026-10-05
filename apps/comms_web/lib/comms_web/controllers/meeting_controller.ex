defmodule CommsWeb.MeetingController do
  use CommsWeb, :controller
  alias CommsCore.AudioCalls
  alias CommsCore.AudioCalls.{CredentialRequest, ProviderCall}
  alias CommsIntegrations.Audio.{LiveKitReadiness, LiveKitToken, RoomService}
  alias CommsWeb.{Broadcast, MeetingPresenter, Presenter}

  plug(CommsWeb.Plugs.RequireSecureTransport when action in [:start])

  def index(conn, params) do
    with {:ok, result} <- AudioCalls.list_meetings(conn.assigns.current_subject, params) do
      json(conn, %{
        data: Enum.map(result.meetings, &MeetingPresenter.meeting/1),
        meta: %{
          truncated: result.truncated,
          calendar: %{ics: true, google: false, microsoft: false}
        }
      })
    end
  end

  def show(conn, %{"meeting_id" => id}) do
    with {:ok, meeting} <- AudioCalls.get_meeting(id, conn.assigns.current_subject),
         do: json(conn, %{data: MeetingPresenter.meeting(meeting)})
  end

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, meeting} <-
           AudioCalls.schedule_meeting(conversation_id, params, conn.assigns.current_subject),
         do: conn |> put_status(:created) |> json(%{data: MeetingPresenter.meeting(meeting)})
  end

  def update(conn, %{"meeting_id" => id} = params) do
    with {:ok, meeting} <- AudioCalls.update_meeting(id, params, conn.assigns.current_subject),
         do: json(conn, %{data: MeetingPresenter.meeting(meeting)})
  end

  def cancel(conn, %{"meeting_id" => id} = params) do
    with {:ok, meeting} <- AudioCalls.cancel_meeting(id, params, conn.assigns.current_subject),
         do: json(conn, %{data: MeetingPresenter.meeting(meeting)})
  end

  def calendar(conn, %{"meeting_id" => id}) do
    with {:ok, ics} <- AudioCalls.meeting_calendar(id, conn.assigns.current_subject),
         do: json(conn, %{data: %{ics: ics, filename: "meeting-#{id}.ics"}})
  end

  def start(conn, %{"meeting_id" => id, "occurrence_id" => occurrence_id} = params) do
    subject = conn.assigns.current_subject

    with {:ok, kind} <- media_kind(params["media_kind"]),
         :ok <- LiveKitReadiness.ensure_available(),
         {:ok, meeting} <- AudioCalls.get_meeting(id, subject),
         occurrence when not is_nil(occurrence) <-
           Enum.find(meeting.occurrences, &(&1.id == occurrence_id)),
         {:ok, result} <-
           AudioCalls.start_meeting(
             id,
             occurrence_id,
             subject,
             kind,
             &delete_room/1,
             &issue(
               &1,
               conn.assigns.current_user.display_name,
               subject.user_id,
               occurrence.ends_at
             )
           ) do
      if result.status == :created do
        payload = Presenter.audio_call(result.call)
        Broadcast.event(meeting.conversation_id, "call.started.v1", payload)

        if kind == :audio,
          do: Broadcast.event(meeting.conversation_id, "audio_call.started.v1", payload)
      end

      conn
      |> put_status(if(result.status == :created, do: :created, else: :ok))
      |> json(%{data: Presenter.audio_call(result.call), credential: result.credential})
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp media_kind("audio"), do: {:ok, :audio}
  defp media_kind("video"), do: {:ok, :video}
  defp media_kind(_), do: {:error, :invalid_media_kind}
  defp delete_room(%ProviderCall{provider_room: room}), do: RoomService.delete_room(room)

  defp issue(
         %CredentialRequest{provider_room: room, media_kind: kind, provider_identity: identity},
         name,
         user_id,
         expires_at
       ),
       do: LiveKitToken.issue(room, kind, identity, name, expires_at, %{"user_id" => user_id})
end
