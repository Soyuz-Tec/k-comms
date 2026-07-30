defmodule CommsCore.Accounts.Sessions.RefreshTokens do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{Device, Session, User}
  alias CommsCore.Accounts.Sessions.Persistence
  alias CommsCore.{Administration, Repo}

  @session_bytes 32

  def refresh(token) when is_binary(token) do
    with {:ok, session_id, secret} <- parse_refresh_token(token) do
      case Repo.transaction(fn ->
             session =
               Repo.one(
                 from(s in Session,
                   where: s.id == ^session_id,
                   lock: "FOR UPDATE"
                 )
               )

             rotate_refresh_session(session, secret)
           end) do
        {:ok, result} -> result
        {:error, _reason} -> {:error, :invalid_refresh_token}
      end
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  def refresh_guest(token) when is_binary(token) do
    with {:ok, session_id, secret} <- parse_refresh_token(token) do
      case Repo.transaction(fn ->
             session =
               Repo.one(
                 from(s in Session,
                   where: s.id == ^session_id,
                   lock: "FOR UPDATE"
                 )
               )

             rotate_guest_refresh_session(session, secret)
           end) do
        {:ok, result} -> result
        {:error, _reason} -> {:error, :invalid_refresh_token}
      end
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  def create(user, device) do
    id = Ecto.UUID.generate()
    {token, hash} = new_refresh_token(id)
    created_at = Persistence.now()
    deadlines = new_deadlines(created_at)

    changeset =
      Session.changeset(%Session{id: id}, %{
        tenant_id: user.tenant_id,
        user_id: user.id,
        device_id: device.id,
        refresh_token_hash: hash,
        expires_at: deadlines.expires_at,
        absolute_expires_at: deadlines.absolute_expires_at,
        last_used_at: created_at
      })

    case Repo.insert(changeset) do
      {:ok, session} -> {:ok, session, token}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_or_rollback(user, device) do
    case create(user, device) do
      {:ok, session, refresh_token} -> {session, refresh_token}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def create_guest_or_rollback(user, device, guest_expires_at, created_at) do
    id = Ecto.UUID.generate()
    {refresh_token, refresh_hash} = new_refresh_token(id)

    expires_at =
      earlier_deadline(
        DateTime.add(created_at, session_ttl_seconds(), :second),
        guest_expires_at
      )

    session =
      %Session{id: id}
      |> Session.changeset(%{
        tenant_id: user.tenant_id,
        user_id: user.id,
        device_id: device.id,
        refresh_token_hash: refresh_hash,
        expires_at: expires_at,
        absolute_expires_at: guest_expires_at,
        last_used_at: created_at
      })
      |> insert_or_rollback()

    {session, refresh_token}
  end

  def new_deadlines(created_at) do
    absolute_expires_at =
      DateTime.add(created_at, session_absolute_ttl_seconds(), :second)

    %{
      absolute_expires_at: absolute_expires_at,
      expires_at:
        earlier_deadline(
          DateTime.add(created_at, session_ttl_seconds(), :second),
          absolute_expires_at
        )
    }
  end

  def new_refresh_token(session_id) do
    secret = :crypto.strong_rand_bytes(@session_bytes)
    encoded = Base.url_encode64(secret, padding: false)
    {"#{session_id}.#{encoded}", :crypto.hash(:sha256, secret)}
  end

  defp rotate_refresh_session(%Session{} = session, secret) do
    with true <- active_session?(session),
         true <- secure_hash_equals(session.refresh_token_hash, secret),
         %User{status: :active, account_type: :human} = user <-
           Repo.get_by(User, id: session.user_id, tenant_id: session.tenant_id),
         %Device{} = device <-
           Repo.get_by(Device,
             id: session.device_id,
             tenant_id: session.tenant_id,
             user_id: session.user_id
           ),
         true <- is_nil(device.revoked_at),
         {:ok, tenant} <- Administration.active_tenant(session.tenant_id) do
      {new_token, new_hash} = new_refresh_token(session.id)

      case session
           |> Session.changeset(%{
             refresh_token_hash: new_hash,
             last_used_at: Persistence.now(),
             expires_at: rotated_session_expires_at(session.absolute_expires_at)
           })
           |> Repo.update() do
        {:ok, updated} ->
          {:ok,
           %{
             tenant: tenant,
             user: user,
             device: device,
             session: updated,
             refresh_token: new_token
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  defp rotate_refresh_session(nil, _secret), do: {:error, :invalid_refresh_token}

  defp rotate_guest_refresh_session(%Session{} = session, secret) do
    timestamp = Persistence.now()

    with true <- active_session?(session),
         true <- secure_hash_equals(session.refresh_token_hash, secret),
         %User{status: :active, account_type: :guest, guest_expires_at: %DateTime{} = expiry} =
           user <- Repo.get_by(User, id: session.user_id, tenant_id: session.tenant_id),
         true <- DateTime.compare(expiry, timestamp) == :gt,
         %Device{} = device <-
           Repo.get_by(Device,
             id: session.device_id,
             tenant_id: session.tenant_id,
             user_id: session.user_id
           ),
         true <- is_nil(device.revoked_at),
         {:ok, tenant} <- Administration.active_tenant(session.tenant_id) do
      {new_token, new_hash} = new_refresh_token(session.id)

      case session
           |> Session.changeset(%{
             refresh_token_hash: new_hash,
             last_used_at: timestamp,
             expires_at:
               session.absolute_expires_at
               |> earlier_deadline(expiry)
               |> rotated_session_expires_at()
           })
           |> Repo.update() do
        {:ok, updated} ->
          {:ok,
           %{
             tenant: tenant,
             user: user,
             device: device,
             session: updated,
             refresh_token: new_token
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  defp rotate_guest_refresh_session(nil, _secret), do: {:error, :invalid_refresh_token}

  defp parse_refresh_token(token) do
    case String.split(token, ".", parts: 2) do
      [session_id, secret_text] ->
        with {:ok, secret} <- Base.url_decode64(secret_text, padding: false),
             {:ok, _} <- Ecto.UUID.cast(session_id) do
          {:ok, session_id, secret}
        else
          _ -> {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  end

  defp secure_hash_equals(hash, secret) when is_binary(hash) and is_binary(secret) do
    actual = :crypto.hash(:sha256, secret)
    byte_size(actual) == byte_size(hash) and :crypto.hash_equals(actual, hash)
  end

  defp secure_hash_equals(_, _), do: false

  defp active_session?(session) do
    current_time = Persistence.now()

    is_nil(session.revoked_at) and DateTime.compare(session.expires_at, current_time) == :gt and
      DateTime.compare(session.absolute_expires_at, current_time) == :gt
  end

  defp rotated_session_expires_at(absolute_expires_at),
    do:
      earlier_deadline(
        DateTime.add(Persistence.now(), session_ttl_seconds(), :second),
        absolute_expires_at
      )

  defp earlier_deadline(first, second) do
    if DateTime.compare(first, second) == :gt, do: second, else: first
  end

  defp session_ttl_seconds,
    do: Application.get_env(:comms_core, :session_ttl_seconds, 2_592_000) |> max(0)

  defp session_absolute_ttl_seconds,
    do: Application.get_env(:comms_core, :session_absolute_ttl_seconds, 2_592_000) |> max(0)

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
