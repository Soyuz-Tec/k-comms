defmodule CommsCore.Conversations.EphemeralRooms.Request do
  @moduledoc false

  @token_bytes 32
  @token_encoded_bytes 43

  @spec generate_token() :: {binary(), String.t()}
  def generate_token do
    secret = :crypto.strong_rand_bytes(@token_bytes)
    {secret, Base.url_encode64(secret, padding: false)}
  end

  @spec idempotency_secret(term()) ::
          {:ok, binary()} | {:error, :invalid_idempotency_key}
  def idempotency_secret(value)
      when is_binary(value) and byte_size(value) == @token_encoded_bytes do
    case Base.url_decode64(value, padding: false) do
      {:ok, secret} when byte_size(secret) == @token_bytes ->
        if Base.url_encode64(secret, padding: false) == value,
          do: {:ok, secret},
          else: {:error, :invalid_idempotency_key}

      _ ->
        {:error, :invalid_idempotency_key}
    end
  end

  def idempotency_secret(_value), do: {:error, :invalid_idempotency_key}

  @spec token_secret(term()) ::
          {:ok, binary()} | {:error, :ephemeral_room_unavailable}
  def token_secret(value) do
    case idempotency_secret(value) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} -> {:error, :ephemeral_room_unavailable}
    end
  end

  @spec display_name(term()) ::
          {:ok, String.t()} | {:error, :invalid_guest_display_name}
  def display_name(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and String.length(value) <= 120,
      do: {:ok, value},
      else: {:error, :invalid_guest_display_name}
  end

  def display_name(_value), do: {:error, :invalid_guest_display_name}

  @spec device(term()) ::
          {:ok, %{name: String.t(), platform: String.t()}}
          | {:error, :invalid_guest_device}
  def device(device) when is_map(device) do
    name = value(device, :name)
    platform = value(device, :platform)

    if is_binary(name) and String.trim(name) != "" and String.length(name) <= 120 and
         is_binary(platform) and String.trim(platform) != "" and
         String.length(platform) <= 40 do
      {:ok, %{name: String.trim(name), platform: String.trim(platform)}}
    else
      {:error, :invalid_guest_device}
    end
  end

  def device(_value), do: {:error, :invalid_guest_device}

  @spec room_title(term()) ::
          {:ok, String.t()} | {:error, :invalid_ephemeral_room_title}
  def room_title(nil), do: {:ok, "Instant room"}

  def room_title(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, "Instant room"}
      String.length(value) <= 160 -> {:ok, value}
      true -> {:error, :invalid_ephemeral_room_title}
    end
  end

  def room_title(_value), do: {:error, :invalid_ephemeral_room_title}

  @spec create_fingerprint(map(), String.t(), String.t() | nil, map()) :: binary()
  def create_fingerprint(scope, title, display_name, device) do
    digest([
      "create:v1",
      scope.tenant_id,
      Atom.to_string(scope.owner_kind),
      Map.get(scope, :grant) |> then(&if(&1, do: &1.user_id, else: "")),
      title,
      display_name || "",
      value(device, :name) || "",
      value(device, :platform) || ""
    ])
  end

  @spec join_fingerprint(map(), map(), String.t() | nil, map()) :: binary()
  def join_fingerprint(link, scope, display_name, device) do
    digest([
      "join:v1",
      link.id,
      Atom.to_string(scope.account_type),
      Map.get(scope, :user_id, ""),
      display_name || "",
      value(device, :name) || "",
      value(device, :platform) || ""
    ])
  end

  @spec secure_match?(binary(), binary()) :: boolean()
  def secure_match?(left, right)
      when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  def secure_match?(_left, _right), do: false

  @spec digest(iodata()) :: binary()
  def digest(value), do: :crypto.hash(:sha256, value)

  @spec value(map(), atom()) :: term()
  def value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
