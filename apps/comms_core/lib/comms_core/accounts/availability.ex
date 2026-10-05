defmodule CommsCore.Accounts.Availability do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.Accounts.{AccessControl, ProfileValidation, User}
  alias CommsCore.Accounts.Sessions.Persistence
  alias CommsCore.Repo
  @states ["available", "away", "busy", "dnd", "offline"]

  def get(subject) do
    with {:ok, grant} <- AccessControl.access_grant(subject),
         %User{} = user <- Repo.get_by(User, id: grant.user_id, tenant_id: grant.tenant_id) do
      {:ok, view(user)}
    else
      _ -> {:error, :forbidden}
    end
  end

  def update(attrs, subject) do
    with {:ok, grant} <- AccessControl.access_grant(subject),
         {:ok, changes} <- validated(attrs) do
      Repo.transaction(fn ->
        %User{} =
          user =
          Repo.one!(
            from(u in User,
              where: u.id == ^grant.user_id and u.tenant_id == ^grant.tenant_id,
              lock: "FOR UPDATE"
            )
          )

        user = Repo.update!(Ecto.Changeset.change(%User{} = user, changes))

        Persistence.insert_audit!(subject, "identity.availability_updated", "user", user.id, %{
          presence_state: user.presence_state,
          scheduled: map_size(user.dnd_schedule) > 0
        })

        view(user)
      end)
    end
  end

  # Cross-context read returns only delivery decisions, not identity persistence.
  def delivery(tenant_id, user_id, channel)
      when channel in [:email, :push, :in_app, :call, "email", "push", "in_app", "call"] do
    case Repo.get_by(User, id: user_id, tenant_id: tenant_id, status: :active) do
      %User{} = user ->
        %{status: state, dnd_active: active, retry_at: retry_at} = view(user)
        allowed = channel in [:in_app, "in_app"] or not active
        {:ok, %{allowed: allowed, retry_at: if(allowed, do: nil, else: retry_at), status: state}}

      _ ->
        {:error, :not_found}
    end
  end

  def delivery(_, _, _), do: {:error, :invalid_availability_channel}

  def view(user, now \\ Persistence.now()) do
    state =
      if user.presence_expires_at && DateTime.compare(user.presence_expires_at, now) != :gt,
        do: "available",
        else: user.presence_state

    manual = state == "dnd" or (user.dnd_until && DateTime.compare(user.dnd_until, now) == :gt)
    schedule_end = scheduled_end(user.dnd_schedule, user.timezone, now)
    active = manual || schedule_end != nil

    retry_at =
      cond do
        state == "dnd" and is_nil(user.presence_expires_at) -> nil
        state == "dnd" -> user.presence_expires_at
        manual -> user.dnd_until
        true -> schedule_end
      end

    retry_at = if retry_at && schedule_end, do: latest(retry_at, schedule_end), else: retry_at

    %{
      status: if(active, do: "dnd", else: state),
      presence_state: user.presence_state,
      presence_expires_at: user.presence_expires_at,
      dnd_until: user.dnd_until,
      dnd_schedule: user.dnd_schedule,
      dnd_active: !!active,
      retry_at: retry_at,
      timezone: user.timezone
    }
  end

  defdelegate valid_timezone?(zone), to: ProfileValidation
  defdelegate valid_avatar?(avatar), to: ProfileValidation

  defp validated(attrs) do
    state = Persistence.value(attrs, :presence_state) || "available"
    schedule = Persistence.value(attrs, :dnd_schedule) || %{}

    with true <- state in @states,
         {:ok, expires} <- deadline(Persistence.value(attrs, :presence_expires_at)),
         {:ok, until} <- deadline(Persistence.value(attrs, :dnd_until)),
         true <- valid_schedule?(schedule) do
      {:ok,
       %{
         presence_state: state,
         presence_expires_at: expires,
         dnd_until: until,
         dnd_schedule: schedule
       }}
    else
      _ -> {:error, :invalid_availability}
    end
  end

  defp deadline(nil), do: {:ok, nil}
  defp deadline(""), do: {:ok, nil}

  defp deadline(value) when is_binary(value) do
    with {:ok, time, _} <- DateTime.from_iso8601(value),
         true <- DateTime.diff(time, Persistence.now()) in 1..604_800 do
      # ISO input retains its fractional-digit count (JavaScript emits three).
      # Ecto's utc_datetime_usec requires six; preserve the parsed instant.
      {:ok, %{time | microsecond: {elem(time.microsecond, 0), 6}}}
    else
      _ -> {:error, :invalid_availability}
    end
  end

  defp deadline(_), do: {:error, :invalid_availability}
  defp valid_schedule?(schedule) when schedule == %{}, do: true

  defp valid_schedule?(%{"days" => days, "start" => start, "end" => ending} = schedule) do
    is_list(days) and length(days) in 1..7 and Enum.all?(days, &(&1 in 1..7)) and
      length(Enum.uniq(days)) == length(days) and
      valid_time?(start) and valid_time?(ending) and start != ending and
      Enum.all?(Map.keys(schedule), &(&1 in ["days", "start", "end"]))
  end

  defp valid_schedule?(_), do: false

  defp valid_time?(value) when is_binary(value),
    do: Regex.match?(~r/^([01][0-9]|2[0-3]):[0-5][0-9]$/, value)

  defp valid_time?(_), do: false

  defp scheduled_end(%{"days" => days, "start" => start, "end" => ending}, timezone, now) do
    with {:ok, local} <- DateTime.shift_zone(now, timezone, Tzdata.TimeZoneDatabase),
         {:ok, start_time} <- Time.from_iso8601(start <> ":00"),
         {:ok, end_time} <- Time.from_iso8601(ending <> ":00") do
      today = DateTime.to_date(local)

      [Date.add(today, -1), today]
      |> Enum.find_value(fn date ->
        end_date = if Time.compare(end_time, start_time) == :lt, do: Date.add(date, 1), else: date

        if Date.day_of_week(date) in days do
          began = zoned(date, start_time, timezone, :start)
          ended = zoned(end_date, end_time, timezone, :end)

          if began && ended && DateTime.compare(now, began) != :lt &&
               DateTime.compare(now, ended) == :lt,
             do: ended
        end
      end)
    else
      _ -> nil
    end
  end

  defp scheduled_end(_, _, _), do: nil

  defp zoned(date, time, zone, side) do
    case DateTime.new(date, time, zone, Tzdata.TimeZoneDatabase) do
      {:ok, value} -> value
      {:ambiguous, earlier, later} -> if(side == :start, do: earlier, else: later)
      {:gap, _before, after_gap} -> after_gap
      _ -> nil
    end
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)
end
