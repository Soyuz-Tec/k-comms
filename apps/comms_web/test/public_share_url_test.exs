defmodule CommsWeb.PublicShareURLTest do
  use ExUnit.Case, async: false

  alias CommsWeb.PublicShareURL

  setup do
    previous = Application.get_env(:comms_web, :public_share_origin)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:comms_web, :public_share_origin)
      else
        Application.put_env(:comms_web, :public_share_origin, previous)
      end
    end)

    :ok
  end

  test "uses the separately validated qualification share origin" do
    Application.put_env(
      :comms_web,
      :public_share_origin,
      "https://comms.avayaworks.com"
    )

    assert PublicShareURL.build("guest token") ==
             "https://comms.avayaworks.com/join#guest=guest+token"
  end

  test "uses the explicitly configured canonical application origin" do
    Application.put_env(
      :comms_web,
      :public_share_origin,
      "http://localhost:5173"
    )

    assert PublicShareURL.build("guest-token") ==
             "http://localhost:5173/join#guest=guest-token"
  end
end
