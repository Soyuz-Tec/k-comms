defmodule CommsWeb.Administration.WorkspaceDomainControllerTest do
  use CommsWeb.ConnCase, async: false
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.User
  alias CommsTestSupport.Fixtures
  import Ecto.Query
  @moduletag :integration
  @moduletag :administration

  defmodule Resolver do
    @behaviour CommsCore.Administration.DomainTXTResolver
    @impl true
    def lookup(_query), do: {:ok, Application.fetch_env!(:comms_core, :workspace_domain_http_txt)}
  end

  setup do
    old = Application.get_env(:comms_core, :workspace_domain_txt_resolver)
    Application.put_env(:comms_core, :workspace_domain_txt_resolver, Resolver)

    on_exit(fn ->
      if old,
        do: Application.put_env(:comms_core, :workspace_domain_txt_resolver, old),
        else: Application.delete_env(:comms_core, :workspace_domain_txt_resolver)

      Application.delete_env(:comms_core, :workspace_domain_http_txt)
    end)

    :ok
  end

  test "the actual HTTP administrative lifecycle discloses only an explicit verified domain hint" do
    account = Fixtures.account_fixture()
    suffix = account.tenant.slug |> String.split("-") |> List.last()

    assert authenticated(account) |> get("/api/v1/admin/workspace-domains") |> response(428)

    assert authenticated(account)
           |> post("/api/v1/me/step-up", %{current_password: "correct-horse-battery-#{suffix}"})
           |> response(200)

    domain = "http-#{account.user.id}.company.com"

    claim =
      authenticated(account)
      |> post("/api/v1/admin/workspace-domains", %{
        domain: domain,
        version: 0,
        discovery_enabled: true
      })
      |> json_response(201)
      |> Map.fetch!("data")

    assert claim["status"] == "pending"
    assert is_binary(claim["challenge_value"])

    assert discover(%{domain: domain}) == %{
             "data" => %{"available" => false, "sign_in_path" => nil}
           }

    Application.put_env(:comms_core, :workspace_domain_http_txt, [claim["challenge_value"]])

    verified =
      authenticated(account)
      |> post("/api/v1/admin/workspace-domains/#{claim["id"]}/verify", %{version: 1})
      |> json_response(200)
      |> Map.fetch!("data")

    assert verified["version"] == 2
    assert is_nil(verified["challenge_value"])

    assert discover(%{domain: domain}) == %{
             "data" => %{
               "available" => true,
               "sign_in_path" => "/sign-in?tenant_slug=#{account.tenant.slug}"
             }
           }

    assert authenticated(account)
           |> patch("/api/v1/admin/workspace-domains/#{claim["id"]}", %{
             version: 1,
             discovery_enabled: false
           })
           |> response(409)

    assert authenticated(account)
           |> patch("/api/v1/admin/workspace-domains/#{claim["id"]}", %{
             version: 2,
             discovery_enabled: false
           })
           |> response(200)

    assert discover(%{domain: domain}) == %{
             "data" => %{"available" => false, "sign_in_path" => nil}
           }

    assert authenticated(account)
           |> delete("/api/v1/admin/workspace-domains/#{claim["id"]}", %{version: 3})
           |> response(200)

    assert authenticated(account) |> get("/api/v1/admin/workspace-domains") |> json_response(200) ==
             %{"data" => [], "limits" => %{"domains" => 8}}
  end

  test "public unknown malformed email and extra-field probes have the same response" do
    neutral = %{"data" => %{"available" => false, "sign_in_path" => nil}}

    for attrs <- [
          %{domain: "unknown.company.com"},
          %{domain: "person@company.com"},
          %{email: "person@company.com"},
          %{domain: "company.com", email: "person@company.com"},
          %{domain: "https://company.com/path"}
        ] do
      assert discover(attrs) == neutral
    end

    assert build_conn()
           |> put_req_header("origin", "https://foreign.example")
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/workspaces/discover", Jason.encode!(%{domain: "company.com"}))
           |> response(403)
  end

  test "foreign claim IDs and limited human administrators never receive challenges" do
    account = Fixtures.account_fixture()
    Fixtures.step_up(account)

    {:ok, claim} =
      CommsCore.Administration.create_workspace_domain(
        %{domain: "private-#{account.user.id}.company.com", version: 0},
        Fixtures.subject(account)
      )

    other = Fixtures.account_fixture()
    Fixtures.step_up(other)

    assert authenticated(other)
           |> post("/api/v1/admin/workspace-domains/#{claim.id}/challenge", %{version: 1})
           |> response(404)

    Repo.update_all(from(u in User, where: u.id == ^account.user.id),
      set: [access_scope: :conversation_only]
    )

    assert authenticated(account)
           |> get("/api/v1/admin/workspace-domains")
           |> response(403)

    assert authenticated(account)
           |> post("/api/v1/admin/workspace-domains/#{claim.id}/verify", %{version: 1})
           |> response(403)
  end

  test "DNS uncertainty returns 503 and never becomes verification success" do
    account = Fixtures.account_fixture()
    Fixtures.step_up(account)

    {:ok, claim} =
      CommsCore.Administration.create_workspace_domain(
        %{domain: "dns-#{account.user.id}.company.com", version: 0},
        Fixtures.subject(account)
      )

    # Missing resolver state causes a monitored technical worker failure. The
    # owner converts uncertainty to 503 and retains the original claim version.
    assert authenticated(account)
           |> post("/api/v1/admin/workspace-domains/#{claim.id}/verify", %{version: 1})
           |> json_response(503)
           |> get_in(["error", "code"]) == "dns_unavailable"

    {:ok, current} = CommsCore.Administration.list_workspace_domains(Fixtures.subject(account))
    assert hd(current).version == 1
    assert hd(current).status == :pending
    assert {:ok, _grant} = Accounts.access_grant(Fixtures.subject(account))
  end

  defp authenticated(account) do
    token =
      account
      |> Fixtures.authentication_result()
      |> CommsWeb.Token.issue()
      |> Map.fetch!(:access_token)

    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  defp discover(attrs) do
    build_conn()
    |> put_req_header("origin", Application.fetch_env!(:comms_core, :public_app_url))
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/workspaces/discover", Jason.encode!(attrs))
    |> json_response(200)
  end
end
