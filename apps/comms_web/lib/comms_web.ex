defmodule CommsWeb do
  def static_paths, do: ~w(assets app favicon.ico robots.txt)

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]
      import Plug.Conn
      alias CommsWeb.Presenter
      action_fallback(CommsWeb.FallbackController)
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel, do: quote(do: use(Phoenix.Channel))
  defmacro __using__(which), do: apply(__MODULE__, which, [])
end
