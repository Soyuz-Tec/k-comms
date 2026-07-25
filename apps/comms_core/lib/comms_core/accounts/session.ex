defmodule CommsCore.Accounts.Session do
  use CommsCore.Schema

  schema "sessions" do
    field(:tenant_id, Ecto.UUID)
    belongs_to(:user, CommsCore.Accounts.User)
    belongs_to(:device, CommsCore.Accounts.Device)
    field(:refresh_token_hash, :binary, redact: true)
    field(:expires_at, :utc_datetime_usec)
    field(:absolute_expires_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:step_up_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :device_id,
      :refresh_token_hash,
      :expires_at,
      :absolute_expires_at,
      :last_used_at,
      :revoked_at,
      :step_up_at
    ])
    |> validate_required([
      :tenant_id,
      :user_id,
      :device_id,
      :refresh_token_hash,
      :expires_at,
      :absolute_expires_at,
      :last_used_at
    ])
    |> validate_absolute_expiry_immutable(value)
  end

  @doc """
  Extends the authority window for an active instant-room guest session.

  This purpose-specific changeset is the only session changeset allowed to
  move an already-persisted absolute deadline. The owning Accounts facade
  validates the guest identity, transaction, row locks, and maximum horizon.
  """
  def ephemeral_guest_authority_changeset(
        %__MODULE__{__meta__: %{state: :loaded}} = value,
        attrs
      ) do
    value
    |> cast(attrs, [:expires_at, :absolute_expires_at, :last_used_at])
    |> validate_required([:expires_at, :absolute_expires_at, :last_used_at])
    |> validate_ephemeral_authority_extension(value)
  end

  def ephemeral_guest_authority_changeset(value, _attrs) do
    value
    |> change()
    |> add_error(:absolute_expires_at, "requires a persisted guest session")
  end

  defp validate_absolute_expiry_immutable(
         changeset,
         %__MODULE__{__meta__: %{state: :loaded}, absolute_expires_at: current}
       ) do
    case fetch_change(changeset, :absolute_expires_at) do
      {:ok, ^current} -> changeset
      {:ok, _changed} -> add_error(changeset, :absolute_expires_at, "cannot be changed")
      :error -> changeset
    end
  end

  defp validate_absolute_expiry_immutable(changeset, _session), do: changeset

  defp validate_ephemeral_authority_extension(changeset, session) do
    expires_at = get_field(changeset, :expires_at)
    absolute_expires_at = get_field(changeset, :absolute_expires_at)

    changeset
    |> validate_not_before(:expires_at, expires_at, session.expires_at)
    |> validate_not_before(
      :absolute_expires_at,
      absolute_expires_at,
      session.absolute_expires_at
    )
    |> validate_rolling_not_after_absolute(expires_at, absolute_expires_at)
  end

  defp validate_not_before(changeset, field, %DateTime{} = proposed, %DateTime{} = current) do
    if DateTime.compare(proposed, current) == :lt,
      do: add_error(changeset, field, "cannot shorten ephemeral guest authority"),
      else: changeset
  end

  defp validate_not_before(changeset, field, _proposed, _current),
    do: add_error(changeset, field, "is invalid")

  defp validate_rolling_not_after_absolute(
         changeset,
         %DateTime{} = expires_at,
         %DateTime{} = absolute_expires_at
       ) do
    if DateTime.compare(expires_at, absolute_expires_at) == :gt,
      do: add_error(changeset, :expires_at, "cannot exceed absolute expiry"),
      else: changeset
  end

  defp validate_rolling_not_after_absolute(changeset, _expires_at, _absolute_expires_at),
    do: add_error(changeset, :expires_at, "is invalid")
end
