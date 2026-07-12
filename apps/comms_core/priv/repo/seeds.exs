alias CommsCore.Accounts.Tenant
alias CommsCore.Repo
if System.get_env("SEED_DEMO_DATA") == "true" do
  Repo.insert(Tenant.changeset(%Tenant{}, %{name: "K-Comms Development", slug: "k-comms-development", status: :active}), on_conflict: :nothing, conflict_target: :slug)
end
