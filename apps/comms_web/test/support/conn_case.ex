defmodule CommsWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint CommsWeb.Endpoint
      import Plug.Conn
      import Phoenix.ConnTest
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(CommsCore.Repo, shared: not tags[:async])
    CommsWeb.RateLimiter.reset()
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
