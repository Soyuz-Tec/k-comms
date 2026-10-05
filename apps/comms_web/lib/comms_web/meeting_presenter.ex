defmodule CommsWeb.MeetingPresenter do
  alias CommsCore.AudioCalls.MeetingView

  def meeting(%MeetingView{} = meeting) do
    meeting
    |> Map.from_struct()
    |> Map.update!(:local_start, &NaiveDateTime.to_iso8601/1)
  end
end
