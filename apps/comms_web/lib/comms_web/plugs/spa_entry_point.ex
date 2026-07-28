defmodule CommsWeb.Plugs.SpaEntryPoint do
  @moduledoc false

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/app/"} = conn, _opts) do
    %{conn | path_info: ["app", "index.html"]}
  end

  def call(conn, _opts), do: conn
end
