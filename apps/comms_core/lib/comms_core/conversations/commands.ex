defmodule CommsCore.Conversations.Commands do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{Accounts, AdmissionQuotas, Audit, Outbox, Repo}

  alias CommsCore.Conversations.{
    AccessPolicy,
    Conversation,
    Directory,
    GuestAdmission,
    Membership
  }

  def create_view(attrs, subject) do
    create(attrs, subject)
    |> project_result(&Directory.project_authorized_conversation(&1, subject))
  end

  def update_view(id, attrs, subject) do
    __MODULE__.update(id, attrs, subject)
    |> project_result(&Directory.project_authorized_conversation(&1, subject))
  end

  def archive_view(id, attrs, subject, revoke_call_access) do
    archive(id, attrs, subject, revoke_call_access)
    |> project_result(&Directory.project_authorized_conversation(&1, subject))
  end

  def create(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)
    kind = enum_value(value(attrs, :kind), [:direct, :group, :channel], :group)
    member_ids = normalize_member_ids(value(attrs, :member_ids), user_id)

    visibility = enum_value(value(attrs, :visibility), [:private, :tenant], :private)
    visibility = if kind == :direct, do: :private, else: visibility
    title = if kind == :direct, do: nil, else: value(attrs, :title)

    with :ok <- AccessPolicy.authorize_create(subject),
         :ok <- validate_members(tenant_id, member_ids),
         :ok <- AccessPolicy.validate_public_channel(subject, kind, visibility),
         {:ok, direct_key} <- direct_key(kind, member_ids) do
      timestamp = now()

      Repo.transaction(fn ->
        policy = admission_policy!(tenant_id)
        current_active_conversations = active_conversation_count(tenant_id)

        quota_ok!(
          AdmissionQuotas.check_conversation_creation(
            policy,
            current_active_conversations,
            length(member_ids)
          )
        )

        conversation =
          %Conversation{}
          |> Conversation.changeset(%{
            tenant_id: tenant_id,
            created_by_user_id: user_id,
            kind: kind,
            title: title,
            visibility: visibility,
            direct_key: direct_key,
            next_sequence: 1
          })
          |> insert_or_rollback()

        Enum.each(member_ids, fn member_id ->
          role = if member_id == user_id, do: :owner, else: :member

          %Membership{}
          |> Membership.changeset(%{
            tenant_id: tenant_id,
            conversation_id: conversation.id,
            user_id: member_id,
            role: role,
            joined_at: timestamp,
            last_read_sequence: 0
          })
          |> insert_or_rollback()
        end)

        insert_event(conversation, "conversation.created.v1", subject, %{
          kind: kind,
          title: conversation.title,
          member_ids: member_ids
        })

        conversation
      end)
    end
  rescue
    error in Ecto.ConstraintError -> {:error, constraint_reason(error)}
  end

  def update(id, attrs, subject) when is_map(attrs) do
    with :ok <- AccessPolicy.authorize_manage(id, subject),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation =
          Repo.one(
            from(c in Conversation,
              where:
                c.id == ^id and c.tenant_id == ^value(subject, :tenant_id) and
                  is_nil(c.archived_at),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if conversation.lock_version != expected_version, do: Repo.rollback(:stale_version)

        changes =
          %{}
          |> maybe_put(:title, value(attrs, :title))
          |> maybe_put(:visibility, normalized_visibility(value(attrs, :visibility)))
          |> enforce_direct_fields(conversation)

        requested_visibility = Map.get(changes, :visibility, conversation.visibility)

        case AccessPolicy.validate_public_channel(
               subject,
               conversation.kind,
               requested_visibility
             ) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        updated =
          conversation
          |> Conversation.changeset(changes)
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_event(updated, "conversation.updated.v1", subject, %{
          before: %{title: conversation.title, visibility: conversation.visibility},
          after: %{title: updated.title, visibility: updated.visibility},
          version: updated.lock_version
        })

        updated
      end)
      |> transaction_result()
    end
  end

  def archive(id, attrs, subject, revoke_call_access)
      when is_map(attrs) and is_function(revoke_call_access, 3) do
    with :ok <- AccessPolicy.authorize_manage(id, subject),
         {:ok, expected_version} <- expected_version(attrs) do
      Repo.transaction(fn ->
        conversation =
          Repo.one(
            from(c in Conversation,
              where: c.id == ^id and c.tenant_id == ^value(subject, :tenant_id),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if conversation.lock_version != expected_version, do: Repo.rollback(:stale_version)
        if conversation.archived_at, do: Repo.rollback(:conversation_archived)

        archived =
          conversation
          |> Conversation.changeset(%{archived_at: now()})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        insert_event(archived, "conversation.archived.v1", subject, %{
          version: archived.lock_version
        })

        revoke_call_access.(archived.tenant_id, archived.id, "conversation_archived")

        archived
      end)
      |> transaction_result()
    end
  end

  def mark_read(conversation_id, sequence, subject) when is_integer(sequence) do
    with :ok <- AccessPolicy.authorize_mark_read(conversation_id, subject),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation,
             id: conversation_id,
             tenant_id: value(subject, :tenant_id)
           ) do
      target = sequence |> max(0) |> min(max(conversation.next_sequence - 1, 0))
      timestamp = now()

      query =
        from(m in Membership,
          where:
            m.conversation_id == ^conversation_id and
              m.user_id == ^value(subject, :user_id) and
              m.tenant_id == ^value(subject, :tenant_id) and is_nil(m.left_at)
        )

      update_query =
        from(m in query,
          update: [
            set: [
              last_read_sequence: fragment("GREATEST(?, ?)", m.last_read_sequence, ^target),
              updated_at: ^timestamp
            ]
          ]
        )

      case Repo.update_all(update_query, []) do
        {1, _} -> {:ok, target}
        _ -> {:error, :not_found}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def mark_read(_, _, _), do: {:error, :invalid_sequence}

  @doc false
  def insert_event(conversation, type, subject, payload) do
    timestamp = now()

    Outbox.insert_and_enqueue!(%{
      tenant_id: conversation.tenant_id,
      event_type: type,
      aggregate_type: "conversation",
      aggregate_id: conversation.id,
      payload: Map.put(payload, :conversation_id, conversation.id),
      available_at: timestamp
    })

    Audit.record(%{
      tenant_id: conversation.tenant_id,
      actor_user_id: value(subject, :user_id),
      action: String.replace(type, ".v1", ""),
      resource_type: "conversation",
      resource_id: conversation.id,
      metadata: payload,
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

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

  @doc false
  def transaction_result({:ok, result}), do: {:ok, result}
  def transaction_result({:error, reason}), do: {:error, reason}

  @doc false
  def quota_ok!(:ok), do: :ok
  def quota_ok!({:error, reason}), do: Repo.rollback(reason)

  @doc false
  def admission_policy!(tenant_id) do
    case AdmissionQuotas.locked_policy(tenant_id) do
      {:ok, policy} -> policy
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  def active_conversation_count(tenant_id) do
    Conversation
    |> where(
      [conversation],
      conversation.tenant_id == ^tenant_id and is_nil(conversation.archived_at)
    )
    |> Repo.aggregate(:count)
  end

  @doc false
  def ensure_conversation_member_capacity(policy, %Conversation{} = conversation) do
    timestamp = now()

    current_active_members =
      Membership
      |> join(:inner, [membership], joined_conversation in Conversation,
        on:
          joined_conversation.id == membership.conversation_id and
            joined_conversation.tenant_id == membership.tenant_id
      )
      |> join(
        :left,
        [membership, _joined_conversation],
        guest_admission in GuestAdmission,
        on:
          guest_admission.tenant_id == membership.tenant_id and
            guest_admission.membership_id == membership.id and
            is_nil(guest_admission.converted_at)
      )
      |> where(
        [membership, joined_conversation, guest_admission],
        membership.tenant_id == ^conversation.tenant_id and
          membership.conversation_id == ^conversation.id and
          joined_conversation.tenant_id == ^conversation.tenant_id and
          is_nil(joined_conversation.archived_at) and is_nil(membership.left_at) and
          (is_nil(guest_admission.id) or
             (is_nil(guest_admission.revoked_at) and guest_admission.expires_at > ^timestamp))
      )
      |> Repo.aggregate(:count)

    AdmissionQuotas.check_conversation_member_capacity(policy, current_active_members)
  end

  @doc false
  def expected_version(attrs) do
    case value(attrs, :version) || value(attrs, :lock_version) do
      version when is_integer(version) and version > 0 ->
        {:ok, version}

      version when is_binary(version) ->
        case Integer.parse(version) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, :version_required}
        end

      _ ->
        {:error, :version_required}
    end
  end

  @doc false
  def value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc false
  def enum_value(value, allowed, default) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in allowed, do: atom, else: default
  rescue
    ArgumentError -> default
  end

  def enum_value(value, allowed, default) when is_atom(value) do
    if value in allowed, do: value, else: default
  end

  def enum_value(_, _, default), do: default

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp validate_members(tenant_id, member_ids) do
    active_user_ids = Accounts.resolve_active_user_ids(tenant_id, member_ids)

    if MapSet.new(active_user_ids) == MapSet.new(member_ids),
      do: :ok,
      else: {:error, :invalid_members}
  end

  defp direct_key(:direct, member_ids) when length(member_ids) == 2 do
    {:ok, member_ids |> Enum.sort() |> Enum.join(":")}
  end

  defp direct_key(:direct, _), do: {:error, :direct_conversation_requires_two_members}
  defp direct_key(_, _), do: {:ok, nil}

  defp normalize_member_ids(ids, owner_id) do
    ids = if is_list(ids), do: ids, else: []
    [owner_id | ids] |> Enum.filter(&is_binary/1) |> Enum.uniq()
  end

  defp normalized_visibility(nil), do: nil

  defp normalized_visibility(value),
    do: enum_value(value, [:private, :tenant], :invalid_visibility)

  defp enforce_direct_fields(attrs, %Conversation{kind: :direct}) do
    attrs
    |> Map.put(:title, nil)
    |> Map.put(:visibility, :private)
  end

  defp enforce_direct_fields(attrs, _), do: attrs

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error

  defp constraint_reason(%Ecto.ConstraintError{constraint: constraint}) do
    if String.contains?(constraint, "direct_key"),
      do: :direct_conversation_exists,
      else: :conflict
  end
end
