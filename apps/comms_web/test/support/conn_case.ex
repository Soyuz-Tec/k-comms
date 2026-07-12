defmodule CommsWeb.ConnCase do
  use ExUnit.CaseTemplate
  using do
    quote do
      @endpoint CommsWeb.Endpoint
      use Phoenix.ConnTest
    end
  end
  setup _tags, do: {:ok, conn: Phoenix.ConnTest.build_conn()}
end
