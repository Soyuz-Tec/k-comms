defmodule CommsIntegrations.LocalReleaseGuard.QualificationAppTest do
  use ExUnit.Case, async: true

  alias CommsIntegrations.LocalReleaseGuard
  import CommsIntegrations.LocalReleaseGuardTestOptions

  @moduletag :unit
  @moduletag :release

  test "accepts one confirmed isolated qualification app CORS origin" do
    for qualification_origin <- [
          "http://127.0.0.1:1024",
          "http://127.0.0.1:45231",
          "http://127.0.0.1:65535"
        ] do
      assert :ok =
               LocalReleaseGuard.validate!(qualification_options(qualification_origin))
    end
  end

  test "accepts qualification CORS without changing a retained loopback public origin" do
    qualification_origin = "http://127.0.0.1:45231"

    assert :ok =
             LocalReleaseGuard.validate!(
               options(
                 role: "edge",
                 instant_room_tenant_slug:
                   "k-comms-qualification-0123456789abcdef0123456789abcdef",
                 qualification_app_origin: qualification_origin,
                 qualification_app_confirmation: "local-release-qualification-app-v1",
                 qualification_share_origin: "http://127.0.0.1:4188",
                 cors_origins: [qualification_origin]
               )
             )
  end

  test "qualification app can preserve the sealed RFC1918 share origin" do
    qualification_origin = "http://127.0.0.1:45231"

    assert :ok =
             LocalReleaseGuard.validate!(
               options(
                 role: "edge",
                 instant_room_tenant_slug:
                   "k-comms-qualification-0123456789abcdef0123456789abcdef",
                 qualification_app_origin: qualification_origin,
                 qualification_app_confirmation: "local-release-qualification-app-v1",
                 qualification_share_origin: "http://192.168.50.25:4188",
                 cors_origins: [qualification_origin]
               )
             )

    for invalid <- [
          "http://192.168.50.25:4189",
          "http://192.168.050.25:4188",
          "http://192.168.50.25:4188/",
          "http://203.0.113.25:4188"
        ] do
      assert_raise ArgumentError, ~r/K_COMMS_QUALIFICATION_SHARE_ORIGIN/, fn ->
        LocalReleaseGuard.validate!(
          options(
            role: "edge",
            instant_room_tenant_slug: "k-comms-qualification-0123456789abcdef0123456789abcdef",
            qualification_app_origin: qualification_origin,
            qualification_app_confirmation: "local-release-qualification-app-v1",
            qualification_share_origin: invalid,
            cors_origins: [qualification_origin]
          )
        )
      end
    end
  end

  test "qualification share origin accepts the sealed local or public origin only" do
    qualification_origin = "http://127.0.0.1:45231"

    assert :ok =
             LocalReleaseGuard.validate!(
               qualification_options(qualification_origin)
               |> Keyword.put(:qualification_share_origin, "http://192.168.50.25:4188")
             )

    for invalid <- [
          nil,
          "",
          qualification_origin,
          "http://comms.avayaworks.com",
          "https://comms.avayaworks.com/",
          "https://COMMS.avayaworks.com",
          "https://comms.avayaworks.com:444",
          "https://127.0.0.1",
          "https://example.invalid"
        ] do
      assert_raise ArgumentError, ~r/K_COMMS_QUALIFICATION_SHARE_ORIGIN/, fn ->
        LocalReleaseGuard.validate!(
          qualification_options(qualification_origin)
          |> Keyword.put(:qualification_share_origin, invalid)
        )
      end
    end
  end

  test "qualification app mode does not broaden retained release CSP or CORS" do
    qualification_origin = "http://127.0.0.1:45231"
    qualification_options = qualification_options(qualification_origin)

    for cors_origins <- [
          [],
          ["http://192.168.50.25:4188"],
          ["http://127.0.0.1:45232"],
          [qualification_origin, "http://192.168.50.25:4188"],
          [qualification_origin, qualification_origin]
        ] do
      assert_raise ArgumentError, ~r/CORS_ORIGINS must contain exactly/, fn ->
        LocalReleaseGuard.validate!(
          Keyword.put(qualification_options, :cors_origins, cors_origins)
        )
      end
    end

    assert_raise ArgumentError, ~r/CSP_CONNECT_SOURCES must be an exact/, fn ->
      LocalReleaseGuard.validate!(
        Keyword.put(
          qualification_options,
          :csp_connect_sources,
          ["'self'", "ws://192.168.50.25:7980", qualification_origin]
        )
      )
    end
  end

  test "qualification app mode requires every isolation gate" do
    qualification_options = qualification_options("http://127.0.0.1:45231")

    for {field, value, error} <- [
          {:enabled?, false, ~r/requires K_COMMS_LOCAL_RELEASE=true/},
          {:role, "all", ~r/requires K_COMMS_ROLE=edge/},
          {:runtime_purpose, "one_shot", ~r/only for an application runtime/},
          {:allow_bootstrap?, true, ~r/requires ALLOW_BOOTSTRAP=false/},
          {:instant_room_tenant_slug, "k-comms-development",
           ~r/requires INSTANT_ROOM_TENANT_SLUG/},
          {:instant_room_tenant_slug, "k-comms-qualification-0123456789abcdef0123456789abcdeG",
           ~r/requires INSTANT_ROOM_TENANT_SLUG/},
          {:qualification_app_confirmation, nil,
           ~r/K_COMMS_QUALIFICATION_APP_CONFIRMATION must exactly equal/},
          {:qualification_app_confirmation, "local-release-qualification-app-v2",
           ~r/K_COMMS_QUALIFICATION_APP_CONFIRMATION must exactly equal/}
        ] do
      assert_raise ArgumentError, error, fn ->
        LocalReleaseGuard.validate!(Keyword.put(qualification_options, field, value))
      end
    end
  end

  test "qualification app origin is one canonical loopback non-public port" do
    for invalid <- [
          nil,
          "",
          "http://localhost:45231",
          "http://127.0.0.1",
          "http://127.0.0.1:80",
          "http://127.0.0.1:4188",
          "http://127.0.0.1:045231",
          "http://127.0.0.1:45231/",
          "http://127.0.0.1:45231/path",
          "http://127.0.0.1:45231?query=true",
          "http://127.0.0.1:45231#fragment",
          "http://user@127.0.0.1:45231",
          " http://127.0.0.1:45231",
          "http://127.0.0.1:45231 ",
          "http://127.0.0.1:45231\n",
          "https://127.0.0.1:45231",
          "http://127.0.0.1:65536"
        ] do
      assert_raise ArgumentError, ~r/must be an exact canonical/, fn ->
        LocalReleaseGuard.validate!(
          qualification_options(invalid)
          |> Keyword.put(:cors_origins, [invalid])
        )
      end
    end
  end

  test "a partial qualification confirmation fails closed" do
    assert_raise ArgumentError, ~r/K_COMMS_QUALIFICATION_APP_ORIGIN must be an exact/, fn ->
      LocalReleaseGuard.validate!(qualification_options(nil))
    end
  end
end
