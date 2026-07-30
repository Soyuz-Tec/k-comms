defmodule CommsWeb.StatusCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use CommsWeb.ConnCase, async: false

      import CommsWeb.StatusCase, only: [eventually: 1, restore_env: 2, restore_env: 3]
    end
  end

  def eventually(fun, attempts \\ 80)

  def eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  def eventually(_fun, 0), do: false

  def restore_env(key, value), do: restore_env(:comms_core, key, value)
  def restore_env(app, key, nil), do: Application.delete_env(app, key)
  def restore_env(app, key, value), do: Application.put_env(app, key, value)
end
