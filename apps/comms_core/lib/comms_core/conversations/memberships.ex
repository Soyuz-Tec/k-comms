defmodule CommsCore.Conversations.Memberships do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, Repo}

  alias CommsCore.Conversations.{
    AccessPolicy,
    Commands,
    Conversation,
    Membership,
    Projector
  }

  def add_view(conversation_id, user_id, role, subject),
    do:
      add(conversation_id, user_id, role, subject)
      |> project_result(&Projector.membership/1)

  def remove_view(conversation_id, user_id, attrs, subject, revoke_call_access),
    do:
      remove(conversation_id, user_id, attrs, subject, revoke_call_access)
      |> project_result(&Projector.membership/1)

  def change_role_view(conversation_id, user_id, attrs, subject),
    do:
      change_role(conversation_id, user_id, attrs, subject)
      |> project_result(&Projector.membership/1)

  def add(conversation_id, user_id, role, subject) do
    with :ok <- AccessPolicy.authorize_manage(conversation_id, subject),
         {:ok, assigned_role} <- membership_role(role) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)

        authorize_in_transaction!(fn ->
          AccessPolicy.authorize_manage(conversation.id, subject)
        end)

        policy = Commands.admission_policy!(conversation.tenant_id)

        unless Accounts.resolve_active_user_ids(conversation.tenant_id, [user_id]) == [user_id],
          do: Repo.rollback(:invalid_member)

        timestamp = Commands.now()

        {membership, changed?} =
          case Repo.one(
                 from(m in Membership,
                   where:
                     m.conversation_id == ^conversation_id and m.user_id == ^user_id and
                       m.tenant_id == ^conversation.tenant_id,
                   lock: "FOR UPDATE"
                 )
               ) do
            nil ->
              authorize_ownership_change!(nil, assigned_role, subject, conversation)

              Commands.quota_ok!(
                Commands.ensure_conversation_member_capacity(policy, conversation)
              )

              %Membership{}
              |> Membership.changeset(%{
                tenant_id: conversation.tenant_id,
                conversation_id: conversation_id,
                user_id: user_id,
                role: assigned_role,
                joined_at: timestamp,
                left_at: nil,
                last_read_sequence: 0
              })
              |> insert_or_rollback()
              |> then(&{&1, true})

            %Membership{left_at: nil} = membership ->
              authorize_ownership_change!(
                membership.role,
                assigned_role,
                subject,
                conversation
              )

              if membership.role == assigned_role do
                {membership, false}
              else
                Repo.rollback(:version_required)
              end

            membership ->
              authorize_ownership_change!(nil, assigned_role, subject, conversation)

              Commands.quota_ok!(
                Commands.ensure_conversation_member_capacity(policy, conversation)
              )

              membership
              |> Membership.changeset(%{
                role: assigned_role,
                joined_at: timestamp,
                left_at: nil
              })
              |> Ecto.Changeset.optimistic_lock(:lock_version)
              |> update_or_rollback()
              |> then(&{&1, true})
          end

        if changed? do
          Commands.insert_event(conversation, "membership.changed.v1", subject, %{
            user_id: user_id,
            action: "added",
            role: assigned_role
          })
        end

        membership
      end)
    else
      {:error, _} = error -> error
    end
  end

  def remove(conversation_id, user_id, attrs, subject, revoke_call_access)
      when is_map(attrs) and is_function(revoke_call_access, 4) do
    with :ok <- AccessPolicy.authorize_manage(conversation_id, subject),
         {:ok, expected_version} <- Commands.expected_version(attrs) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)

        authorize_in_transaction!(fn ->
          AccessPolicy.authorize_manage(conversation.id, subject)
        end)

        lock_memberships!(conversation_id, conversation.tenant_id)

        membership =
          Repo.get_by(Membership,
            conversation_id: conversation_id,
            user_id: user_id,
            tenant_id: conversation.tenant_id
          ) || Repo.rollback(:not_found)

        if membership.left_at, do: Repo.rollback(:not_found)
        authorize_ownership_change!(membership.role, nil, subject, conversation)
        if membership.lock_version != expected_version, do: Repo.rollback(:stale_version)
        ensure_conversation_owner_remains!(membership)

        updated =
          membership
          |> Membership.changeset(%{left_at: Commands.now()})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        Commands.insert_event(conversation, "membership.changed.v1", subject, %{
          user_id: user_id,
          action: "removed",
          role: membership.role
        })

        revoke_call_access.(
          conversation.tenant_id,
          conversation.id,
          updated.user_id,
          "membership_removed"
        )

        updated
      end)
      |> Commands.transaction_result()
    end
  end

  def change_role(conversation_id, user_id, attrs, subject) when is_map(attrs) do
    with :ok <- AccessPolicy.authorize_manage(conversation_id, subject),
         {:ok, expected_version} <- Commands.expected_version(attrs),
         {:ok, role} <- membership_role(Commands.value(attrs, :role)) do
      Repo.transaction(fn ->
        conversation = lock_conversation!(conversation_id, subject)
        reject_direct_membership_change!(conversation)

        authorize_in_transaction!(fn ->
          AccessPolicy.authorize_manage(conversation.id, subject)
        end)

        lock_memberships!(conversation_id, conversation.tenant_id)

        membership =
          Repo.one(
            from(m in Membership,
              where:
                m.conversation_id == ^conversation_id and m.user_id == ^user_id and
                  m.tenant_id == ^conversation.tenant_id and is_nil(m.left_at)
            )
          ) || Repo.rollback(:not_found)

        authorize_ownership_change!(membership.role, role, subject, conversation)
        if membership.lock_version != expected_version, do: Repo.rollback(:stale_version)

        if membership.role == :owner and role != :owner,
          do: ensure_conversation_owner_remains!(membership)

        updated =
          membership
          |> Membership.changeset(%{role: role})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        Commands.insert_event(conversation, "membership.role_changed.v1", subject, %{
          user_id: user_id,
          before_role: membership.role,
          role: updated.role,
          version: updated.lock_version
        })

        updated
      end)
      |> Commands.transaction_result()
    end
  end

  defp lock_conversation!(conversation_id, subject) do
    Repo.one(
      from(c in Conversation,
        where:
          c.id == ^conversation_id and
            c.tenant_id == ^Commands.value(subject, :tenant_id) and
            is_nil(c.archived_at),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp lock_memberships!(conversation_id, tenant_id) do
    Repo.all(
      from(m in Membership,
        where: m.conversation_id == ^conversation_id and m.tenant_id == ^tenant_id,
        select: m.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp reject_direct_membership_change!(%Conversation{kind: :direct}),
    do: Repo.rollback(:direct_membership_immutable)

  defp reject_direct_membership_change!(_conversation), do: :ok

  defp authorize_in_transaction!(authorization) when is_function(authorization, 0) do
    case authorization.() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_ownership_change!(current_role, requested_role, subject, conversation)
       when current_role == :owner or requested_role == :owner do
    authorize_in_transaction!(fn ->
      AccessPolicy.authorize_manage_ownership(conversation.id, subject)
    end)
  end

  defp authorize_ownership_change!(_current_role, _requested_role, _subject, _conversation),
    do: :ok

  defp ensure_conversation_owner_remains!(%Membership{role: :owner} = membership) do
    remaining =
      Membership
      |> where(
        [m],
        m.tenant_id == ^membership.tenant_id and
          m.conversation_id == ^membership.conversation_id and m.id != ^membership.id and
          m.role == :owner and is_nil(m.left_at)
      )
      |> Repo.aggregate(:count)

    if remaining == 0, do: Repo.rollback(:cannot_remove_owner)
  end

  defp ensure_conversation_owner_remains!(_), do: :ok

  defp membership_role(value) do
    case Commands.enum_value(value, [:member, :moderator, :owner], nil) do
      nil -> {:error, :invalid_role}
      role -> {:ok, role}
    end
  end

  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
