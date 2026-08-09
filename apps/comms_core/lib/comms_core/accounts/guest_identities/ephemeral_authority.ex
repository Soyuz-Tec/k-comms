defmodule CommsCore.Accounts.GuestIdentities.EphemeralAuthority do
  @moduledoc false

  alias CommsCore.Accounts.{Session, User}

  alias CommsCore.Accounts.GuestIdentities.{
    ActiveSession,
    Persistence,
    Validation
  }

  alias CommsCore.Repo

  @type receipt :: %{
          tenant_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          session_id: Ecto.UUID.t(),
          expires_at: DateTime.t()
        }

  @spec extend(Ecto.UUID.t(), DateTime.t() | String.t()) ::
          {:ok, receipt()}
          | {:error, :transaction_required | :invalid_ephemeral_guest_deadline | :session_expired}
  def extend(session_id, deadline) when is_binary(session_id) do
    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      match?({:error, :invalid_uuid}, Validation.uuid(session_id)) ->
        {:error, :session_expired}

      true ->
        with {:ok, deadline} <- Validation.ephemeral_deadline(deadline) do
          extend_in_transaction(session_id, deadline)
        end
    end
  end

  def extend(_session_id, _deadline) do
    if Repo.in_transaction?(),
      do: {:error, :session_expired},
      else: {:error, :transaction_required}
  end

  @spec ensure(Ecto.UUID.t(), DateTime.t() | String.t()) ::
          {:ok, receipt()}
          | {:error, :transaction_required | :invalid_ephemeral_guest_deadline | :session_expired}
  def ensure(session_id, deadline) when is_binary(session_id) do
    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      match?({:error, :invalid_uuid}, Validation.uuid(session_id)) ->
        {:error, :session_expired}

      true ->
        with {:ok, deadline} <- Validation.ephemeral_deadline(deadline) do
          ensure_in_transaction(session_id, deadline)
        end
    end
  end

  def ensure(_session_id, _deadline) do
    if Repo.in_transaction?(),
      do: {:error, :session_expired},
      else: {:error, :transaction_required}
  end

  defp extend_in_transaction(session_id, deadline) do
    timestamp = Persistence.now()

    case ActiveSession.lock_active(session_id, timestamp) do
      nil ->
        {:error, :session_expired}

      %Session{} = active_session ->
        rolling_deadline = rolling_deadline(timestamp, deadline)

        if DateTime.compare(rolling_deadline, deadline) == :lt do
          {:error, :invalid_ephemeral_guest_deadline}
        else
          persist_authority(active_session, deadline, deadline, rolling_deadline, deadline)
        end
    end
  end

  defp ensure_in_transaction(session_id, deadline) do
    timestamp = Persistence.now()

    case ActiveSession.lock_active(session_id, timestamp) do
      nil ->
        {:error, :session_expired}

      %Session{} = active_session ->
        if authority_covered?(active_session, deadline) do
          {:ok, receipt(active_session, deadline)}
        else
          absolute_deadline = later_deadline(active_session.absolute_expires_at, deadline)
          user_deadline = later_deadline(active_session.user.guest_expires_at, deadline)

          rolling_deadline =
            timestamp
            |> rolling_deadline(absolute_deadline)
            |> later_deadline(active_session.expires_at)

          if DateTime.compare(rolling_deadline, deadline) == :lt do
            {:error, :invalid_ephemeral_guest_deadline}
          else
            persist_authority(
              active_session,
              user_deadline,
              absolute_deadline,
              rolling_deadline,
              deadline
            )
          end
        end
    end
  end

  defp persist_authority(
         active_session,
         user_deadline,
         absolute_deadline,
         rolling_deadline,
         receipt_deadline
       ) do
    user_changeset =
      User.guest_expiration_changeset(active_session.user, user_deadline)

    session_changeset =
      Session.ephemeral_guest_authority_changeset(active_session, %{
        expires_at: rolling_deadline,
        absolute_expires_at: absolute_deadline
      })

    with :ok <- valid_changeset(user_changeset),
         :ok <- valid_changeset(session_changeset) do
      _user = update_or_rollback(user_changeset)
      updated_session = update_or_rollback(session_changeset)
      {:ok, receipt(updated_session, receipt_deadline)}
    end
  end

  defp rolling_deadline(timestamp, absolute_deadline) do
    timestamp
    |> DateTime.add(session_ttl_seconds(), :second)
    |> earlier_deadline(absolute_deadline)
  end

  defp authority_covered?(session, deadline) do
    covers?(session.user.guest_expires_at, deadline) and
      covers?(session.absolute_expires_at, deadline) and
      covers?(session.expires_at, deadline)
  end

  defp covers?(current_deadline, requested_deadline),
    do: DateTime.compare(current_deadline, requested_deadline) in [:eq, :gt]

  defp receipt(session, deadline) do
    %{
      tenant_id: session.tenant_id,
      user_id: session.user_id,
      session_id: session.id,
      expires_at: deadline
    }
  end

  defp earlier_deadline(first, second) do
    if DateTime.compare(first, second) == :gt, do: second, else: first
  end

  defp later_deadline(first, second) do
    if DateTime.compare(first, second) == :lt, do: second, else: first
  end

  defp session_ttl_seconds,
    do: Application.get_env(:comms_core, :session_ttl_seconds, 2_592_000) |> max(0)

  defp valid_changeset(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid_changeset(%Ecto.Changeset{}), do: {:error, :invalid_ephemeral_guest_deadline}

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
