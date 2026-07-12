alias CommsCore.Accounts

if System.get_env("SEED_DEMO_DATA") == "true" do
  attrs = %{
    tenant_name: System.get_env("SEED_TENANT_NAME", "K-Comms Development"),
    tenant_slug: System.get_env("SEED_TENANT_SLUG", "k-comms-development"),
    display_name: System.get_env("SEED_OWNER_NAME", "Development Owner"),
    email: System.get_env("SEED_OWNER_EMAIL", "owner@k-comms.local"),
    password: System.get_env("SEED_OWNER_PASSWORD", "change-this-demo-password"),
    device_name: "Seed",
    device_platform: "server"
  }

  case Accounts.bootstrap_tenant(attrs) do
    {:ok, _} -> IO.puts("Seeded demo tenant #{attrs.tenant_slug}")
    {:error, %Ecto.Changeset{errors: errors}} -> IO.inspect(errors, label: "Seed skipped")
    {:error, reason} -> IO.inspect(reason, label: "Seed skipped")
  end
end
