defmodule CommsWeb.IntegrationSafetyOpsCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use CommsWeb.ConnCase, async: false

      defp bootstrap_owner do
        suffix = System.unique_integer([:positive, :monotonic])

        response =
          build_conn()
          |> post("/api/v1/bootstrap", %{
            tenant_name: "Integration Test #{suffix}",
            tenant_slug: "integration-test-#{suffix}",
            display_name: "Owner",
            email: "owner-#{suffix}@example.test",
            password: "correct-horse-battery-#{suffix}"
          })
          |> json_response(201)

        %{token: response["access_token"], password: "correct-horse-battery-#{suffix}"}
      end

      defp authenticated_conn(token) do
        build_conn() |> put_req_header("authorization", "Bearer #{token}")
      end
    end
  end
end
