defmodule CommsCore.Accounts.GuestIdentities.Validation do
  @moduledoc false

  alias CommsCore.Security.Password

  def password(password) do
    if Password.valid_password?(password), do: :ok, else: {:error, :weak_password}
  end

  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(_email), do: ""

  def ephemeral_conversion_subject?(subject),
    do: value(subject, :guest_authority_purpose) == :ephemeral_room

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
end
