defmodule CommsCore.AudioCalls.MeetingCallPolicy do
  @moduledoc false

  import Ecto.Query
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.AudioCalls.{Meeting, MeetingOccurrence}

  def meeting_for_call(tenant_id, call_id) do
    Repo.one(
      from(occurrence in MeetingOccurrence,
        where: occurrence.tenant_id == ^tenant_id and occurrence.call_id == ^call_id,
        select: %{meeting_id: occurrence.meeting_id, occurrence_id: occurrence.id}
      )
    )
  end

  # The existing admission transaction already holds conversation/call locks.
  # Read the durable owner fence here without reversing tenant protection locks.
  # Meeting erasure revokes admissions under those same established call locks.
  def authorize_call_access!(call, subject) do
    association =
      Repo.one(
        from(occurrence in MeetingOccurrence,
          join: meeting in Meeting,
          on: meeting.id == occurrence.meeting_id and meeting.tenant_id == occurrence.tenant_id,
          where: occurrence.tenant_id == ^call.tenant_id and occurrence.call_id == ^call.id,
          select: %{meeting: meeting, occurrence: occurrence}
        )
      )

    if association do
      %{meeting: meeting, occurrence: occurrence} = association

      unless is_nil(meeting.erasure_requested_at) and is_nil(meeting.erased_at) and
               meeting.status == :scheduled and occurrence.status == :scheduled and
               occurrence.meeting_version == meeting.version,
             do: Repo.rollback(:meeting_cancelled)

      if DateTime.compare(now(), occurrence.ends_at) != :lt,
        do: Repo.rollback(:meeting_not_joinable)

      with {:ok, grant} <- Accounts.access_grant(subject) do
        if grant.account_type == :guest and meeting.host_policy["allow_guests"] != true,
          do: Repo.rollback(:meeting_guests_disabled)
      else
        _ -> Repo.rollback(:forbidden)
      end
    end

    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
