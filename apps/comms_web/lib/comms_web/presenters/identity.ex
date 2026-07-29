defmodule CommsWeb.Presenters.Identity do
  @moduledoc false

  alias CommsCore.Accounts.{
    DeviceView,
    DirectoryPersonView,
    RetainedSenderLabelView,
    SessionView,
    UserView
  }

  alias CommsCore.Administration.InvitedIdentityReceipt

  def user(%UserView{} = user) do
    %{
      id: user.id,
      tenant_id: user.tenant_id,
      display_name: user.display_name,
      email: if(user.account_type == :guest, do: nil, else: user.email),
      account_type: user.account_type,
      access_scope: user.access_scope,
      role: user.role,
      status: user.status,
      version: user.version
    }
  end

  def user(%InvitedIdentityReceipt{} = user) do
    %{
      id: user.id,
      tenant_id: user.tenant_id,
      display_name: user.display_name,
      email: user.email,
      account_type: user.account_type,
      role: user.role,
      status: user.status,
      version: user.version
    }
  end

  def identity_user(%UserView{} = user) do
    Map.merge(user(user), %{
      platform_role: user.platform_role,
      platform_role_expires_at: user.platform_role_expires_at
    })
  end

  def guest_identity(%UserView{} = user) do
    %{
      id: user.id,
      tenant_id: user.tenant_id,
      display_name: user.display_name,
      account_type: user.account_type,
      access_scope: user.access_scope,
      role: user.role,
      status: user.status,
      guest_expires_at: user.guest_expires_at
    }
  end

  def admin_user(%UserView{} = user), do: identity_user(user)

  def directory_person(%DirectoryPersonView{} = person) do
    %{id: person.id, display_name: person.display_name}
  end

  def retained_sender_label(%RetainedSenderLabelView{} = label) do
    %{id: label.id, display_name: label.display_name, redacted: label.redacted}
  end

  def device(%DeviceView{} = device) do
    %{
      id: device.id,
      user_id: device.user_id,
      name: device.name,
      platform: device.platform,
      last_seen_at: device.last_seen_at,
      revoked_at: device.revoked_at
    }
  end

  def session(%SessionView{} = session) do
    Map.merge(
      %{
        id: session.id,
        user_id: session.user_id,
        device_id: session.device_id,
        expires_at: session.expires_at,
        last_used_at: session.last_used_at,
        revoked_at: session.revoked_at,
        inserted_at: session.inserted_at
      },
      %{
        platform_role: session.platform_role,
        platform_role_expires_at: session.platform_role_expires_at
      }
    )
  end
end
