defmodule CommsCore.Notifications.Preference do
  use CommsCore.Schema

  schema "notification_preferences" do
    field(:tenant_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:email_enabled, :boolean, default: true)
    field(:push_enabled, :boolean, default: false)
    field(:in_app_enabled, :boolean, default: true)
    field(:muted_event_types, {:array, :string}, default: [])
    timestamps()
  end

  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [
      :tenant_id,
      :user_id,
      :email_enabled,
      :push_enabled,
      :in_app_enabled,
      :muted_event_types
    ])
    |> validate_required([
      :tenant_id,
      :user_id,
      :email_enabled,
      :push_enabled,
      :in_app_enabled,
      :muted_event_types
    ])
    |> validate_length(:muted_event_types, max: 100)
    |> unique_constraint([:tenant_id, :user_id])
    |> foreign_key_constraint(:user_id, name: :notification_preferences_tenant_user_id_fk)
  end
end
