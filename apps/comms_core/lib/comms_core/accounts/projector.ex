defmodule CommsCore.Accounts.Projector do
  @moduledoc false

  alias CommsCore.Accounts.{
    AccessContext,
    AuthenticationResult,
    Device,
    DeviceView,
    PlatformAccess,
    Session,
    SessionView,
    User,
    UserView
  }

  alias CommsCore.Administration.Projector, as: AdministrationProjector

  def user(%User{} = user, opts \\ []) do
    platform_access =
      if Keyword.get(opts, :platform_access, false) do
        PlatformAccess.for_user(user)
      else
        %{platform_role: nil, platform_role_expires_at: nil}
      end

    struct!(UserView, %{
      id: user.id,
      tenant_id: user.tenant_id,
      display_name: user.display_name,
      email: if(user.account_type == :service, do: nil, else: user.email),
      account_type: user.account_type,
      role: user.role,
      status: user.status,
      version: user.lock_version,
      platform_role: platform_access.platform_role,
      platform_role_expires_at: platform_access.platform_role_expires_at
    })
  end

  def device(%Device{} = device) do
    struct!(DeviceView, %{
      id: device.id,
      user_id: device.user_id,
      name: device.name,
      platform: device.platform,
      last_seen_at: device.last_seen_at,
      revoked_at: device.revoked_at
    })
  end

  def session(%Session{} = session) do
    platform_access =
      case session.user do
        %User{} = user -> PlatformAccess.for_user(user)
        _ -> %{platform_role: nil, platform_role_expires_at: nil}
      end

    struct!(SessionView, %{
      id: session.id,
      user_id: session.user_id,
      device_id: session.device_id,
      expires_at: session.expires_at,
      last_used_at: session.last_used_at,
      revoked_at: session.revoked_at,
      inserted_at: session.inserted_at,
      step_up_at: session.step_up_at,
      platform_role: platform_access.platform_role,
      platform_role_expires_at: platform_access.platform_role_expires_at
    })
  end

  def authentication(result) when is_map(result) do
    struct!(AuthenticationResult, %{
      session_id: result.session.id,
      refresh_token: result.refresh_token,
      tenant: AdministrationProjector.tenant(result.tenant),
      user: user(result.user, platform_access: true),
      device: device(result.device),
      conversation: Map.get(result, :conversation)
    })
  end

  def access_context(%Session{} = session, subject) do
    struct!(AccessContext, %{
      subject: subject,
      session: session(session),
      tenant: AdministrationProjector.tenant(session.tenant),
      user: user(session.user, platform_access: true),
      device: device(session.device)
    })
  end
end
