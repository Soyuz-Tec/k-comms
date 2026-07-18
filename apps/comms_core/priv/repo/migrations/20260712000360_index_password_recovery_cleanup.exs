defmodule CommsCore.Repo.Migrations.IndexPasswordRecoveryCleanup do
  use Ecto.Migration

  def change do
    create index(:password_recovery_requests, [:expires_at],
             name: :password_recovery_requests_cleanup_index
           )
  end
end
