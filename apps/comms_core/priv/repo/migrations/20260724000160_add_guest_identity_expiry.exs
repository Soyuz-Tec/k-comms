defmodule CommsCore.Repo.Migrations.AddGuestIdentityExpiry do
  use Ecto.Migration

  def up do
    drop(constraint(:users, :users_account_type_allowed))

    alter table(:users) do
      add(:guest_expires_at, :utc_datetime_usec)
    end

    alter table(:socket_tickets) do
      add(:access_scope, :map, null: false, default: %{})
    end

    create(
      constraint(:users, :users_account_type_allowed,
        check: "account_type IN ('human', 'service', 'guest')"
      )
    )

    create(
      constraint(:users, :users_guest_expiry_required,
        check: "account_type <> 'guest' OR guest_expires_at IS NOT NULL"
      )
    )

    create(
      index(:users, [:tenant_id, :guest_expires_at],
        name: :users_active_guest_expiry_index,
        where: "account_type = 'guest' AND status = 'active'"
      )
    )
  end

  def down do
    drop(index(:users, [:tenant_id, :guest_expires_at], name: :users_active_guest_expiry_index))
    drop(constraint(:users, :users_guest_expiry_required))
    drop(constraint(:users, :users_account_type_allowed))

    execute("""
    UPDATE users
    SET account_type = 'human',
        status = 'suspended',
        guest_expires_at = NULL
    WHERE account_type = 'guest'
    """)

    alter table(:users) do
      remove(:guest_expires_at)
    end

    alter table(:socket_tickets) do
      remove(:access_scope)
    end

    create(
      constraint(:users, :users_account_type_allowed,
        check: "account_type IN ('human', 'service')"
      )
    )
  end
end
