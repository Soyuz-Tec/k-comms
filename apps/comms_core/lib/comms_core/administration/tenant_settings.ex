defmodule CommsCore.Administration.TenantSettings do
  use CommsCore.Schema

  schema "tenant_settings" do
    belongs_to(:tenant, CommsCore.Accounts.Tenant)
    field(:allow_public_channels, :boolean, default: true)
    field(:message_edit_window_seconds, :integer, default: 86_400)
    field(:max_attachment_bytes, :integer, default: 26_214_400)
    field(:default_retention_days, :integer)
    field(:max_active_users, :integer, default: 500)
    field(:max_active_conversations, :integer, default: 2_000)
    field(:max_conversation_members, :integer, default: 250)
    field(:lock_version, :integer, default: 1)
    timestamps()
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :tenant_id,
      :allow_public_channels,
      :message_edit_window_seconds,
      :max_attachment_bytes,
      :default_retention_days,
      :max_active_users,
      :max_active_conversations,
      :max_conversation_members
    ])
    |> validate_required([
      :tenant_id,
      :allow_public_channels,
      :message_edit_window_seconds,
      :max_attachment_bytes,
      :max_active_users,
      :max_active_conversations,
      :max_conversation_members
    ])
    |> validate_number(:message_edit_window_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:max_attachment_bytes,
      greater_than: 0,
      less_than_or_equal_to: 1_073_741_824
    )
    |> validate_number(:default_retention_days, greater_than: 0, less_than_or_equal_to: 36_500)
    |> validate_number(:max_active_users, greater_than: 0, less_than_or_equal_to: 1_000_000)
    |> validate_number(:max_active_conversations,
      greater_than: 0,
      less_than_or_equal_to: 10_000_000
    )
    |> validate_number(:max_conversation_members,
      greater_than_or_equal_to: 2,
      less_than_or_equal_to: 100_000
    )
    |> check_constraint(:max_active_users,
      name: :tenant_settings_max_active_users_bounded
    )
    |> check_constraint(:max_active_conversations,
      name: :tenant_settings_max_active_conversations_bounded
    )
    |> check_constraint(:max_conversation_members,
      name: :tenant_settings_max_conversation_members_bounded
    )
    |> unique_constraint(:tenant_id)
  end
end
