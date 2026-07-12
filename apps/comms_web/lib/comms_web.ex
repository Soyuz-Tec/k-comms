defmodule CommsWeb do
  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]
      import Plug.Conn
    end
  end
  def router, do: quote(do: use Phoenix.Router)
  def channel, do: quote(do: use Phoenix.Channel)
  defmacro __using__(which), do: apply(__MODULE__, which, [])
end
