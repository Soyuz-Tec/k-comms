defmodule CommsCore.Accounts.ConversationBootstrapPortTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts.{
    ConversationBootstrapPort,
    Device,
    InitialConversationCommand,
    InitialConversationReceipt,
    Session,
    Tenant,
    User
  }

  alias CommsCore.Conversations.{Conversation, Membership}
  alias CommsCore.{Accounts, Audit, Repo}

  defmodule FailingAdapter do
    @behaviour CommsCore.Accounts.ConversationBootstrapPort

    @impl true
    def create_initial_channel(%CommsCore.Accounts.InitialConversationCommand{} = command) do
      send(self(), {:initial_conversation_command, command})
      {:error, :forced_conversation_failure}
    end

    @impl true
    def fetch_initial_channel(_tenant_id, _owner_user_id),
      do: {:error, :forced_conversation_failure}
  end

  defmodule MalformedAdapter do
    @behaviour CommsCore.Accounts.ConversationBootstrapPort

    alias CommsCore.Accounts.{InitialConversationCommand, InitialConversationReceipt}

    @impl true
    def create_initial_channel(%InitialConversationCommand{} = command) do
      send(self(), {:initial_conversation_command, command})
      {:ok, receipt(Ecto.UUID.generate(), command.tenant_id, command.owner_user_id)}
    end

    @impl true
    def fetch_initial_channel(_tenant_id, owner_user_id) do
      {:ok, receipt(Ecto.UUID.generate(), Ecto.UUID.generate(), owner_user_id)}
    end

    defp receipt(id, tenant_id, owner_user_id) do
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %InitialConversationReceipt{
        id: id,
        tenant_id: tenant_id,
        owner_user_id: owner_user_id,
        kind: :channel,
        title: "General",
        visibility: :tenant,
        latest_sequence: 0,
        archived_at: nil,
        version: 1,
        inserted_at: timestamp,
        updated_at: timestamp
      }
    end
  end

  setup do
    previous_adapter =
      Application.fetch_env(:comms_core, :identity_conversation_bootstrap_adapter)

    Application.put_env(
      :comms_core,
      :identity_conversation_bootstrap_adapter,
      CommsCore.Conversations
    )

    on_exit(fn ->
      case previous_adapter do
        {:ok, adapter} ->
          Application.put_env(
            :comms_core,
            :identity_conversation_bootstrap_adapter,
            adapter
          )

        :error ->
          Application.delete_env(:comms_core, :identity_conversation_bootstrap_adapter)
      end
    end)

    :ok
  end

  test "the bootstrap owner port rejects work outside a repository transaction" do
    command = initial_conversation_command()

    assert {:error, :transaction_required} =
             ConversationBootstrapPort.create_initial_channel(command)

    assert {:error, :transaction_required} =
             ConversationBootstrapPort.fetch_initial_channel(
               command.tenant_id,
               command.owner_user_id
             )
  end

  test "a failed conversation owner command rolls back every bootstrap contribution" do
    suffix = System.unique_integer([:positive, :monotonic])

    Application.put_env(
      :comms_core,
      :identity_conversation_bootstrap_adapter,
      FailingAdapter
    )

    assert {:error, :forced_conversation_failure} =
             Accounts.bootstrap_tenant(%{
               tenant_name: "Port rollback #{suffix}",
               tenant_slug: "port-rollback-#{suffix}",
               display_name: "Port rollback owner",
               email: "port-rollback-#{suffix}@example.test",
               password: "correct-horse-port-rollback-#{suffix}",
               device_name: "Rollback browser",
               device_platform: "test"
             })

    assert_receive {:initial_conversation_command, %InitialConversationCommand{} = command}

    assert_bootstrap_absent(command)
  end

  test "a malformed successful receipt fails closed and rolls back bootstrap" do
    Application.put_env(
      :comms_core,
      :identity_conversation_bootstrap_adapter,
      MalformedAdapter
    )

    assert {:error, :conversation_owner_unavailable} =
             Accounts.bootstrap_tenant(interactive_bootstrap_attrs("malformed"))

    assert_receive {:initial_conversation_command, %InitialConversationCommand{} = command}
    assert_bootstrap_absent(command)
  end

  test "release bootstrap rolls back when the conversation owner fails" do
    Application.put_env(
      :comms_core,
      :identity_conversation_bootstrap_adapter,
      FailingAdapter
    )

    attrs = release_bootstrap_attrs("owner-failure")

    assert {:error, :forced_conversation_failure} = Accounts.bootstrap_tenant_once(attrs)
    assert_receive {:initial_conversation_command, %InitialConversationCommand{} = command}
    assert_bootstrap_absent(command)
  end

  test "release retry rejects a malformed owner receipt" do
    attrs = release_bootstrap_attrs("malformed-fetch")
    assert {:ok, created} = Accounts.bootstrap_tenant_once(attrs)

    Application.put_env(
      :comms_core,
      :identity_conversation_bootstrap_adapter,
      MalformedAdapter
    )

    assert {:error, :conversation_owner_unavailable} = Accounts.bootstrap_tenant_once(attrs)
    assert Repo.get(Tenant, created.tenant.id)
    assert Repo.get(User, created.user.id)
    assert Repo.get(Conversation, created.conversation.id)
  end

  test "release retry rejects an archived initial conversation" do
    attrs = release_bootstrap_attrs("archived")
    assert {:ok, created} = Accounts.bootstrap_tenant_once(attrs)

    Conversation
    |> Repo.get!(created.conversation.id)
    |> Conversation.changeset(%{
      archived_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()

    assert {:error, :bootstrap_identity_conflict} = Accounts.bootstrap_tenant_once(attrs)
  end

  test "release retry rejects a missing initial owner membership" do
    attrs = release_bootstrap_attrs("missing-membership")
    assert {:ok, created} = Accounts.bootstrap_tenant_once(attrs)

    created.conversation.id
    |> then(&Repo.get_by!(Membership, conversation_id: &1, user_id: created.user.id))
    |> Repo.delete!()

    assert {:error, :bootstrap_identity_conflict} = Accounts.bootstrap_tenant_once(attrs)
  end

  test "release retry rejects ambiguous initial conversations" do
    attrs = release_bootstrap_attrs("ambiguous")
    assert {:ok, created} = Accounts.bootstrap_tenant_once(attrs)

    %Conversation{}
    |> Conversation.changeset(%{
      tenant_id: created.tenant.id,
      created_by_user_id: created.user.id,
      kind: :channel,
      title: "General",
      visibility: :tenant,
      next_sequence: 1
    })
    |> Repo.insert!()

    assert {:error, :bootstrap_identity_conflict} = Accounts.bootstrap_tenant_once(attrs)
  end

  defp initial_conversation_command do
    %InitialConversationCommand{
      id: Ecto.UUID.generate(),
      tenant_id: Ecto.UUID.generate(),
      owner_user_id: Ecto.UUID.generate(),
      joined_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  defp interactive_bootstrap_attrs(label) do
    suffix = System.unique_integer([:positive, :monotonic])

    %{
      tenant_name: "Port #{label} #{suffix}",
      tenant_slug: "port-#{label}-#{suffix}",
      display_name: "Port owner",
      email: "port-#{label}-#{suffix}@example.test",
      password: "correct-horse-port-#{label}-#{suffix}",
      device_name: "Port browser",
      device_platform: "test"
    }
  end

  defp release_bootstrap_attrs(label) do
    suffix = System.unique_integer([:positive, :monotonic])

    %{
      tenant_name: "Release #{label} #{suffix}",
      tenant_slug: "release-#{label}-#{suffix}",
      display_name: "Release owner",
      email: "release-#{label}-#{suffix}@example.test",
      password: "correct-horse-release-#{label}-#{suffix}"
    }
  end

  defp assert_bootstrap_absent(command) do
    refute Repo.get(Tenant, command.tenant_id)
    refute Repo.get(User, command.owner_user_id)
    refute Repo.get(Conversation, command.id)
    refute Repo.get_by(Membership, conversation_id: command.id)
    refute Repo.get_by(Device, tenant_id: command.tenant_id)
    refute Repo.get_by(Session, tenant_id: command.tenant_id)

    assert Audit.count(%{
             tenant_id: command.tenant_id,
             action: "tenant.bootstrap"
           }) == 0
  end
end
