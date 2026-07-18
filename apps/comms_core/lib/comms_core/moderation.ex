defmodule CommsCore.Moderation do
  import Ecto.Query

  alias CommsCore.{Accounts, Conversations, Messaging}
  alias CommsCore.Accounts.AccessGrant
  alias CommsCore.Audit
  alias CommsCore.Messaging.GovernanceImpact
  alias CommsCore.Moderation.{ModerationAction, ModerationCase}
  alias CommsCore.Repo

  @max_limit 100

  @doc false
  def authorize_report(subject) when is_map(subject) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{}} -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  def authorize_report(_subject), do: {:error, :forbidden}

  @doc false
  def authorize_read(subject),
    do:
      authorize_roles(
        subject,
        :moderate_tenant,
        [:owner, :admin, :moderator, :compliance_admin],
        false
      )

  @doc false
  def authorize_manage(subject),
    do:
      authorize_roles(
        subject,
        :manage_moderation,
        [:owner, :admin, :moderator, :compliance_admin],
        true
      )

  def create_case_view(attrs, subject) do
    with {:ok, result} <- create_case(attrs, subject) do
      {:ok, %{result | case: CommsCore.Moderation.Projector.case_view(result.case)}}
    end
  end

  def list_case_views(params, subject) do
    with {:ok, cases} <- list_cases(params, subject) do
      {:ok, Enum.map(cases, &CommsCore.Moderation.Projector.case_view/1)}
    end
  end

  def get_case_view(id, subject) do
    with {:ok, result} <- get_case(id, subject) do
      {:ok,
       %{
         case: CommsCore.Moderation.Projector.case_view(result.case),
         actions: Enum.map(result.actions, &CommsCore.Moderation.Projector.action/1)
       }}
    end
  end

  def add_action_view(case_id, attrs, subject) do
    with {:ok, result} <- add_action(case_id, attrs, subject) do
      {:ok,
       %{
         case: CommsCore.Moderation.Projector.case_view(result.case),
         action: CommsCore.Moderation.Projector.action(result.action)
       }}
    end
  end

  def create_case(attrs, subject) when is_map(attrs) and is_map(subject) do
    tenant_id = value(subject, :tenant_id)
    reporter_id = value(subject, :user_id)
    idempotency_key = value(attrs, :idempotency_key)

    with :ok <- authorize_report(subject),
         {:ok, targets} <- validate_targets(attrs, subject) do
      case existing_case(tenant_id, reporter_id, idempotency_key) do
        %ModerationCase{} = moderation_case ->
          {:ok, %{case: moderation_case, replayed: true}}

        nil ->
          case_id = Ecto.UUID.generate()

          case_attrs = %{
            tenant_id: tenant_id,
            reporter_user_id: reporter_id,
            subject_user_id: targets.subject_user_id,
            conversation_id: targets.conversation_id,
            message_id: targets.message_id,
            category: value(attrs, :category),
            summary: value(attrs, :summary),
            details: value(attrs, :details),
            priority: value(attrs, :priority) || :normal,
            status: :open,
            idempotency_key: idempotency_key
          }

          Ecto.Multi.new()
          |> Ecto.Multi.insert(
            :case,
            ModerationCase.changeset(%ModerationCase{id: case_id}, case_attrs)
          )
          |> Audit.append(
            audit_command(subject, "moderation.case_create", "moderation_case", case_id, %{
              category: value(attrs, :category),
              priority: value(attrs, :priority) || "normal"
            })
          )
          |> Repo.transaction()
          |> case do
            {:ok, %{case: moderation_case}} ->
              {:ok, %{case: moderation_case, replayed: false}}

            {:error, _step, reason, _changes} ->
              {:error, reason}
          end
      end
    end
  end

  def list_cases(params, subject) when is_map(params) do
    with :ok <- authorize_read(subject) do
      limit = parse_limit(value(params, :limit))

      query =
        ModerationCase
        |> where([c], c.tenant_id == ^value(subject, :tenant_id))
        |> maybe_equal(
          :status,
          enum(value(params, :status), [:open, :in_review, :resolved, :dismissed])
        )
        |> maybe_equal(:priority, enum(value(params, :priority), [:low, :normal, :high, :urgent]))
        |> maybe_equal(:category, value(params, :category))
        |> maybe_equal(:assigned_to_user_id, value(params, :assigned_to_user_id))
        |> order_by([c], desc: c.inserted_at)
        |> limit(^limit)

      {:ok, Repo.all(query)}
    end
  end

  def get_case(id, subject) do
    with :ok <- authorize_read(subject),
         %ModerationCase{} = moderation_case <-
           Repo.one(
             from(c in ModerationCase,
               where: c.id == ^id and c.tenant_id == ^value(subject, :tenant_id)
             )
           ) do
      actions =
        Repo.all(
          from(a in ModerationAction,
            where: a.tenant_id == ^value(subject, :tenant_id) and a.moderation_case_id == ^id,
            order_by: [asc: a.inserted_at]
          )
        )

      {:ok, %{case: moderation_case, actions: actions}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def add_action(case_id, attrs, subject) when is_map(attrs) and is_map(subject) do
    with :ok <- authorize_manage(subject),
         {:ok, expected_version} <- expected_version(attrs),
         {:ok, action_type} <- action_type(value(attrs, :action_type)) do
      Repo.transaction(fn ->
        moderation_case =
          Repo.one(
            from(c in ModerationCase,
              where: c.id == ^case_id and c.tenant_id == ^value(subject, :tenant_id),
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if moderation_case.lock_version != expected_version, do: Repo.rollback(:stale_version)

        updates = transition!(moderation_case, action_type, attrs)

        updated_case =
          moderation_case
          |> ModerationCase.changeset(updates)
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> update_or_rollback()

        action =
          %ModerationAction{}
          |> ModerationAction.changeset(%{
            tenant_id: moderation_case.tenant_id,
            moderation_case_id: moderation_case.id,
            actor_user_id: value(subject, :user_id),
            action_type: action_type,
            note: value(attrs, :note),
            metadata: action_metadata(action_type, attrs)
          })
          |> insert_or_rollback()

        subject
        |> audit_command(
          "moderation.#{action_type}",
          "moderation_case",
          moderation_case.id,
          %{
            before_status: moderation_case.status,
            status: updated_case.status,
            version: updated_case.lock_version
          }
        )
        |> Audit.record()
        |> audit_or_rollback()

        %{case: updated_case, action: action}
      end)
      |> transaction_result()
    end
  end

  defp validate_targets(attrs, subject) do
    tenant_id = value(subject, :tenant_id)
    subject_user_id = value(attrs, :subject_user_id)
    requested_conversation_id = value(attrs, :conversation_id)
    message_id = value(attrs, :message_id)

    with :ok <- validate_user_target(tenant_id, subject_user_id),
         {:ok, message_conversation_id} <- validate_message_target(tenant_id, message_id),
         conversation_id <- requested_conversation_id || message_conversation_id,
         :ok <- validate_conversation_target(conversation_id, subject),
         true <- Enum.any?([subject_user_id, conversation_id, message_id], &is_binary/1),
         true <-
           is_nil(requested_conversation_id) or is_nil(message_conversation_id) or
             requested_conversation_id == message_conversation_id do
      {:ok,
       %{
         subject_user_id: subject_user_id,
         conversation_id: conversation_id,
         message_id: message_id
       }}
    else
      false -> {:error, :invalid_moderation_target}
      {:error, _} = error -> error
    end
  end

  defp authorize_roles(subject, action, roles, require_step_up?) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{} = grant} ->
        cond do
          grant.role not in roles ->
            Accounts.audit_authorization_denial(action, subject, :forbidden)

          require_step_up? and not grant.step_up_recent? ->
            Accounts.audit_authorization_denial(action, subject, :step_up_required)

          true ->
            :ok
        end

      {:error, _reason} ->
        Accounts.audit_authorization_denial(action, subject, :forbidden)
    end
  end

  defp validate_user_target(_tenant_id, nil), do: :ok

  defp validate_user_target(tenant_id, user_id) do
    case Accounts.validate_governance_user(tenant_id, user_id) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :invalid_moderation_target}
    end
  end

  defp validate_message_target(_tenant_id, nil), do: {:ok, nil}

  defp validate_message_target(tenant_id, message_id) do
    case Messaging.governance_impact(tenant_id, :message, message_id) do
      %GovernanceImpact{found?: true, conversation_ids: [conversation_id]} ->
        {:ok, conversation_id}

      _ ->
        {:error, :invalid_moderation_target}
    end
  end

  defp validate_conversation_target(nil, _subject), do: :ok

  defp validate_conversation_target(conversation_id, subject) do
    with :ok <- Conversations.validate_reference(value(subject, :tenant_id), conversation_id),
         :ok <- Conversations.authorize_read(conversation_id, subject) do
      :ok
    else
      _ -> {:error, :invalid_moderation_target}
    end
  end

  defp transition!(moderation_case, :note, _attrs), do: %{status: moderation_case.status}

  defp transition!(moderation_case, :assign, attrs) do
    unless moderation_case.status in [:open, :in_review],
      do: Repo.rollback(:invalid_status_transition)

    assignee_id = value(attrs, :assigned_to_user_id)

    case Accounts.validate_moderation_assignee(moderation_case.tenant_id, assignee_id) do
      :ok -> :ok
      {:error, :invalid_assignee} -> Repo.rollback(:invalid_assignee)
    end

    %{assigned_to_user_id: assignee_id, status: :in_review, resolved_at: nil}
  end

  defp transition!(moderation_case, :start_review, _attrs) do
    if moderation_case.status in [:open, :in_review],
      do: %{status: :in_review},
      else: Repo.rollback(:invalid_status_transition)
  end

  defp transition!(moderation_case, action, _attrs) when action in [:resolve, :dismiss] do
    if moderation_case.status in [:open, :in_review] do
      %{status: if(action == :resolve, do: :resolved, else: :dismissed), resolved_at: now()}
    else
      Repo.rollback(:invalid_status_transition)
    end
  end

  defp transition!(moderation_case, :reopen, _attrs) do
    if moderation_case.status in [:resolved, :dismissed],
      do: %{status: :open, resolved_at: nil},
      else: Repo.rollback(:invalid_status_transition)
  end

  defp action_metadata(:assign, attrs),
    do: %{assigned_to_user_id: value(attrs, :assigned_to_user_id)}

  defp action_metadata(_, _), do: %{}

  defp existing_case(_tenant_id, _reporter_id, nil), do: nil

  defp existing_case(tenant_id, reporter_id, key) do
    Repo.get_by(ModerationCase,
      tenant_id: tenant_id,
      reporter_user_id: reporter_id,
      idempotency_key: key
    )
  end

  defp maybe_equal(query, _field, nil), do: query
  defp maybe_equal(query, _field, ""), do: query
  defp maybe_equal(query, field, value), do: where(query, [c], field(c, ^field) == ^value)

  defp expected_version(attrs) do
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

  defp action_type(value) do
    case enum(value, [:note, :assign, :start_review, :resolve, :dismiss, :reopen]) do
      nil -> {:error, :invalid_moderation_action}
      action -> {:ok, action}
    end
  end

  defp enum(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp enum(value, allowed) when is_binary(value),
    do: Enum.find(allowed, &(Atom.to_string(&1) == value))

  defp enum(_, _), do: nil

  defp parse_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_limit(number)
      _ -> 50
    end
  end

  defp parse_limit(_), do: 50

  defp audit_command(subject, action, resource_type, resource_id, metadata) do
    %{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    }
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
