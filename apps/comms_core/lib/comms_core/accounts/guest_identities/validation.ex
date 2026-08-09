defmodule CommsCore.Accounts.GuestIdentities.Validation do
  @moduledoc false

  alias CommsCore.Security.Password

  @ephemeral_guest_authority_max_seconds 86_400

  def password(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(_email), do: ""

  def ephemeral_room_authority?(subject),
    do: value(subject, :guest_authority_purpose) == :ephemeral_room

  def ephemeral_deadline(value) do
    timestamp = now()

    with {:ok, deadline} <- datetime(value),
         true <- DateTime.compare(deadline, timestamp) == :gt,
         seconds when seconds <= @ephemeral_guest_authority_max_seconds <-
           DateTime.diff(deadline, timestamp, :second) do
      {:ok, deadline}
    else
      _ -> {:error, :invalid_ephemeral_guest_deadline}
    end
  end

  def datetime(%DateTime{} = value),
    do: {:ok, DateTime.truncate(value, :microsecond)}

  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _ -> {:error, :invalid_datetime}
    end
  end

  def datetime(_value), do: {:error, :invalid_datetime}

  def uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  def uuid(_value), do: {:error, :invalid_uuid}

  def optional_request_id(value) when is_binary(value) do
    value = String.trim(value)
    if value != "" and String.length(value) <= 200, do: value, else: nil
  end

  def optional_request_id(_value), do: nil

  def value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
