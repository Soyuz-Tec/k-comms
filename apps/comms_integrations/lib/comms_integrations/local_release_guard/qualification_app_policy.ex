defmodule CommsIntegrations.LocalReleaseGuard.QualificationAppPolicy do
  @moduledoc false

  alias CommsIntegrations.LocalReleaseGuard.OriginPolicy

  @confirmation "local-release-qualification-app-v1"
  @tenant_slug ~r/\Ak-comms-qualification-[0-9a-f]{32}\z/
  @port_range 1_024..65_535

  def requested?(options) do
    not is_nil(Keyword.get(options, :qualification_app_origin)) or
      not is_nil(Keyword.get(options, :qualification_app_confirmation)) or
      not is_nil(Keyword.get(options, :qualification_share_origin))
  end

  def origin!(options) do
    if requested?(options) do
      confirmation = Keyword.get(options, :qualification_app_confirmation)

      unless confirmation == @confirmation do
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_CONFIRMATION must exactly equal " <>
                @confirmation
      end

      unless Keyword.get(options, :role) == "edge" do
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires K_COMMS_ROLE=edge"
      end

      unless Keyword.fetch!(options, :runtime_purpose) == "application" do
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires " <>
                "K_COMMS_RUNTIME_PURPOSE=application"
      end

      unless Keyword.get(options, :allow_bootstrap?) == false do
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires ALLOW_BOOTSTRAP=false"
      end

      tenant_slug = Keyword.get(options, :instant_room_tenant_slug)

      unless is_binary(tenant_slug) and Regex.match?(@tenant_slug, tenant_slug) do
        raise ArgumentError,
              "K_COMMS_QUALIFICATION_APP_ORIGIN requires INSTANT_ROOM_TENANT_SLUG " <>
                "to match k-comms-qualification-<32 lowercase hex characters>"
      end

      origin = Keyword.get(options, :qualification_app_origin)
      require_app_origin!(origin, Keyword.fetch!(options, :public_app_url))

      require_share_origin!(
        Keyword.get(options, :qualification_share_origin),
        Keyword.fetch!(options, :public_app_url),
        origin
      )

      origin
    end
  end

  def require_cors!(values, qualification_app_origin) do
    unless values == [qualification_app_origin] do
      raise ArgumentError,
            "CORS_ORIGINS must contain exactly K_COMMS_QUALIFICATION_APP_ORIGIN " <>
              "for the isolated qualification application"
    end
  end

  defp require_share_origin!(share_origin, public_app_url, app_origin) do
    valid? =
      is_binary(share_origin) and share_origin != app_origin and
        (share_origin == public_app_url or
           OriginPolicy.canonical_private_http_origin_on_port?(share_origin, public_app_url) or
           OriginPolicy.canonical_public_https_origin?(share_origin))

    unless valid? do
      raise ArgumentError,
            "K_COMMS_QUALIFICATION_SHARE_ORIGIN must exactly equal PUBLIC_APP_URL " <>
              "or be one canonical RFC1918 HTTP origin on the same port or " <>
              "one canonical public HTTPS origin on port 443"
    end
  end

  defp require_app_origin!(origin, public_app_url) do
    match =
      if is_binary(origin) do
        Regex.run(~r/\Ahttp:\/\/127\.0\.0\.1:([0-9]+)\z/, origin)
      end

    port =
      case match do
        [_, value] ->
          case Integer.parse(value) do
            {parsed, ""} -> if value == Integer.to_string(parsed), do: parsed
            _ -> nil
          end

        _ ->
          nil
      end

    public_app_port = URI.parse(public_app_url || "").port

    unless port in @port_range and port != public_app_port do
      raise ArgumentError,
            "K_COMMS_QUALIFICATION_APP_ORIGIN must be an exact canonical " <>
              "http://127.0.0.1:<non-public port> origin"
    end
  end
end
