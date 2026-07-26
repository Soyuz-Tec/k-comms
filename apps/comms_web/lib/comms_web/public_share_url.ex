defmodule CommsWeb.PublicShareURL do
  @moduledoc """
  Builds bearer invitation URLs on the configured public share origin.

  Normal runtimes fall back to the canonical application URL. The isolated
  release qualifier may use a separately validated public share origin while
  serving its browser on a disposable loopback origin.
  """

  @spec build(String.t()) :: String.t()
  def build(token) when is_binary(token) do
    base_url = Application.fetch_env!(:comms_web, :public_share_origin)

    "#{String.trim_trailing(base_url, "/")}/join#guest=#{URI.encode_www_form(token)}"
  end
end
