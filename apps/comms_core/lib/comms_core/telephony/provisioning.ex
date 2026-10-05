defmodule CommsCore.Telephony.Provisioning do
  @moduledoc false
  import Kernel, except: [inspect: 2]
  import Ecto.Query
  alias CommsCore.{Accounts, Administration, Audit, Repo, ValidationError}
  alias CommsCore.Accounts.AccessGrant

  alias CommsCore.Telephony.{
    Call,
    Number,
    ProvisioningCommand,
    ProvisioningPort,
    ProvisioningRequest
  }

  @lease_seconds 15
  @fields ~w(user_id phone_number extension inbound_trunk_id outbound_trunk_id)
  @uncertain [:applying, :unknown, :reconciling]

  def state(subject) do
    with :ok <- Administration.authorize_administer_tenant(subject),
         {:ok, grant} <- access(subject, false) do
      rows =
        Repo.all(
          from(c in ProvisioningCommand,
            where: c.tenant_id == ^grant.tenant_id,
            order_by: [
              asc:
                fragment(
                  "CASE WHEN ? IN ('applying','unknown','reconciling') THEN 0 ELSE 1 END",
                  c.status
                ),
              desc: c.updated_at,
              desc: c.id
            ],
            limit: 10
          )
        )

      {:ok,
       %{
         provider: ProvisioningPort.status(grant.tenant_id),
         assignment_version: assignment_version(grant.tenant_id),
         commands: Enum.map(rows, &view/1)
       }}
    end
  end

  def inspect(attrs, subject) do
    with :ok <- Administration.authorize_administer_tenant(subject),
         {:ok, _grant} <- access(subject, true),
         :ok <- reason(attrs),
         {:ok, request_id} <- uuid(value(attrs, :idempotency_key)),
         {:ok, expected} <- version(value(attrs, :assignment_version), true),
         {:ok, desired} <- desired(attrs) do
      transaction(fn ->
        grant = lock_owner!(subject, desired["user_id"])
        binding!(desired, grant.tenant_id)
        ready!(grant.tenant_id)
        assignment!(grant.tenant_id, expected)
        no_effect!(grant.tenant_id)

        case Repo.get_by(ProvisioningCommand, tenant_id: grant.tenant_id, request_id: request_id) do
          nil ->
            command =
              Repo.insert!(%ProvisioningCommand{
                tenant_id: grant.tenant_id,
                request_id: request_id,
                assignment_version: expected,
                desired: desired,
                status: :inspecting,
                actor_user_id: grant.user_id,
                actor_device_id: grant.device_id,
                actor_session_id: grant.session_id
              })

            {command, request} = lease!(command, :inspect)

            audit!(
              command,
              grant,
              "telephony.provider_inspection_requested",
              value(attrs, :reason)
            )

            {view(command), request}

          command ->
            if command.desired != desired or command.assignment_version != expected,
              do: Repo.rollback(:idempotency_conflict)

            {view(command), nil}
        end
      end)
    end
  end

  def apply_configuration(id, attrs, subject), do: begin(id, attrs, subject, :apply)
  def reconcile(id, attrs, subject), do: begin(id, attrs, subject, :reconcile)

  defp begin(id, attrs, subject, mode) do
    with :ok <- Administration.authorize_administer_tenant(subject),
         {:ok, initial} <- access(subject, true),
         :ok <- reason(attrs),
         {:ok, id} <- uuid(id),
         {:ok, expected} <- version(value(attrs, :version), false) do
      transaction(fn ->
        preliminary = Repo.get_by(ProvisioningCommand, id: id, tenant_id: initial.tenant_id)
        if is_nil(preliminary), do: Repo.rollback(:not_found)
        # Lock all relevant users in Accounts' canonical order before taking
        # the tenant assignment lock and command row. A second owner lock after
        # assignment would deadlock concurrent admins assigning one another.
        grant = lock_owner!(subject, preliminary.desired["user_id"])
        command = command!(id, grant.tenant_id)
        binding!(command.desired, grant.tenant_id, command.id)
        ready!(grant.tenant_id)
        assignment!(grant.tenant_id, command.assignment_version)
        if command.version != expected, do: Repo.rollback(:stale_version)

        case mode do
          :apply ->
            if command.status != :verified or command.effect_consumed,
              do: Repo.rollback(:telephony_outcome_unknown)

            if not fresh_snapshot?(command.snapshot),
              do: Repo.rollback(:provider_inspection_stale)

            no_effect!(grant.tenant_id, command.id)

          :reconcile ->
            if command.status not in @uncertain,
              do: Repo.rollback(:telephony_reconciliation_unavailable)

            if lease_active?(command), do: Repo.rollback(:telephony_effect_in_progress)
        end

        command =
          change!(command, %{
            status: if(mode == :apply, do: :applying, else: :reconciling),
            actor_user_id: grant.user_id,
            actor_device_id: grant.device_id,
            actor_session_id: grant.session_id,
            failure_reason: nil,
            version: command.version + 1
          })

        {command, request} = lease!(command, mode)
        audit!(command, grant, "telephony.provider_#{mode}_requested", value(attrs, :reason))
        {view(command), request}
      end)
    end
  end

  # Called by the configured adapter immediately before each provider read or effect.
  # The one effect capability is consumed durably before CreateSIPDispatchRule.
  def authorize_io(%ProvisioningRequest{} = request, mode, caller)
      when mode in [:read, :effect] do
    if ProvisioningPort.authorized_adapter?(caller) do
      transaction(fn ->
        preliminary =
          Repo.get_by(ProvisioningCommand, id: request.command_id, tenant_id: request.tenant_id)

        if is_nil(preliminary), do: Repo.rollback(:not_found)
        lock_owner!(actor(preliminary), preliminary.desired["user_id"])
        command = command!(request.command_id, request.tenant_id)
        if actor(command) != actor(preliminary), do: Repo.rollback(:telephony_lease_expired)
        binding!(command.desired, command.tenant_id, command.id)
        ready!(command.tenant_id)
        assignment!(command.tenant_id, command.assignment_version)
        require_lease!(command, request)

        if mode == :effect do
          if request.mode != :apply or command.status != :applying or command.effect_consumed,
            do: Repo.rollback(:telephony_outcome_unknown)

          change!(command, %{effect_consumed: true})
        end

        :ok
      end)
      |> case do
        {:ok, :ok} -> :ok
        error -> error
      end
    else
      {:error, :forbidden}
    end
  end

  def authorize_io(_, _, _), do: {:error, :forbidden}

  def complete(%ProvisioningRequest{} = request, result, subject) do
    with :ok <- Administration.authorize_administer_tenant(subject),
         {:ok, initial} <- access(subject, true) do
      transaction(fn ->
        preliminary =
          Repo.get_by(ProvisioningCommand, id: request.command_id, tenant_id: initial.tenant_id)

        if is_nil(preliminary), do: Repo.rollback(:not_found)
        grant = lock_owner!(subject, preliminary.desired["user_id"])
        command = command!(request.command_id, grant.tenant_id)
        binding!(command.desired, grant.tenant_id, command.id)
        assignment!(command.tenant_id, command.assignment_version)
        require_lease!(command, request)

        case normalize_result(result, command) do
          {:ok, snapshot} when request.mode == :inspect ->
            command =
              change!(command, %{
                status: :verified,
                snapshot: snapshot,
                lease_hash: nil,
                lease_expires_at: nil,
                version: command.version + 1
              })

            audit!(command, grant, "telephony.provider_inspected", nil)
            view(command)

          {:ok, %{"dispatch_ready" => true} = snapshot} ->
            number = Repo.get_by(Number, tenant_id: command.tenant_id) || %Number{}
            parameters = Map.put(command.desired, "tenant_id", command.tenant_id)
            changeset = Number.changeset(number, parameters)

            changeset =
              if number.id,
                do: Ecto.Changeset.optimistic_lock(changeset, :lock_version),
                else: changeset

            case Repo.insert_or_update(changeset) do
              {:ok, _number} -> :ok
              {:error, changeset} -> Repo.rollback(validation_error(changeset))
            end

            command =
              change!(command, %{
                status: :applied,
                snapshot: snapshot,
                failure_reason: nil,
                lease_hash: nil,
                lease_expires_at: nil,
                version: command.version + 1
              })

            audit!(command, grant, "telephony.provider_assignment_applied", nil)
            view(command)

          _ ->
            status =
              if request.mode == :inspect or
                   (request.mode == :apply and not command.effect_consumed),
                 do: :failed,
                 else: :unknown

            command =
              change!(command, %{
                status: status,
                failure_reason: safe_failure(result),
                lease_hash: nil,
                lease_expires_at: nil,
                version: command.version + 1
              })

            view(command)
        end
      end)
    end
  end

  def unresolved_effect?(tenant_id) do
    Repo.exists?(unresolved_query(tenant_id))
  end

  def rollback_hazard_count do
    Repo.aggregate(
      from(c in ProvisioningCommand, where: c.effect_consumed == true or c.status == :applied),
      :count
    )
  end

  def guard_legacy_binding!(phone_number) when is_binary(phone_number) do
    lock_phone!(phone_number)

    if Repo.exists?(unresolved_phone_query(phone_number)),
      do: Repo.rollback(:telephony_outcome_unknown)
  end

  def guard_legacy_binding!(_), do: :ok

  defp lock_owner!(subject, user_id \\ nil) do
    with {:ok, initial} <- access(subject, true),
         {:ok, %{allow_audio_calls: true}} <- Administration.lock_call_policy(initial.tenant_id),
         {:ok, _users} <-
           Accounts.lock_active_human_directory_users(
             initial.tenant_id,
             Enum.uniq([initial.user_id | List.wrap(user_id)])
           ),
         {:ok,
          %AccessGrant{
            account_type: :human,
            access_scope: :workspace,
            step_up_recent?: true,
            role: role
          } = grant} <- Accounts.lock_access_grant(subject),
         true <- role in [:owner, :admin] do
      lock_assignment!(grant.tenant_id)
      grant
    else
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp access(subject, step_up?) do
    case Accounts.access_grant(subject) do
      {:ok, %AccessGrant{account_type: :human, access_scope: :workspace, role: role} = grant}
      when role in [:owner, :admin] ->
        if step_up? and not grant.step_up_recent?,
          do: {:error, :step_up_required},
          else: {:ok, grant}

      _ ->
        {:error, :forbidden}
    end
  end

  defp actor(command),
    do: %{
      tenant_id: command.tenant_id,
      user_id: command.actor_user_id,
      device_id: command.actor_device_id,
      session_id: command.actor_session_id
    }

  defp ready!(tenant_id) do
    if ProvisioningPort.status(tenant_id)[:ready] != true,
      do: Repo.rollback(:telephony_provisioning_disabled)
  end

  defp assignment_version(tenant_id) do
    case Repo.get_by(Number, tenant_id: tenant_id) do
      nil -> 0
      number -> number.lock_version
    end
  end

  defp assignment!(tenant_id, expected) do
    if assignment_version(tenant_id) != expected, do: Repo.rollback(:stale_version)

    if Repo.exists?(
         from(c in Call, where: c.tenant_id == ^tenant_id and c.status in [:ringing, :answered])
       ),
       do: Repo.rollback(:active_call_conflict)
  end

  defp lock_assignment!(tenant_id) do
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "assignment:" <> tenant_id
    ])
  end

  defp no_effect!(tenant_id, except \\ nil) do
    query = unresolved_query(tenant_id)
    query = if except, do: where(query, [c], c.id != ^except), else: query
    if Repo.exists?(query), do: Repo.rollback(:telephony_outcome_unknown)
  end

  defp unresolved_query(tenant_id) do
    timestamp = now()

    from(c in ProvisioningCommand,
      where:
        c.tenant_id == ^tenant_id and c.status in ^@uncertain and
          (c.effect_consumed == true or c.lease_expires_at > ^timestamp)
    )
  end

  defp unresolved_phone_query(phone_number) do
    timestamp = now()

    from(c in ProvisioningCommand,
      where:
        fragment("?->>'phone_number'", c.desired) == ^phone_number and
          c.status in ^@uncertain and
          (c.effect_consumed == true or c.lease_expires_at > ^timestamp)
    )
  end

  defp lock_phone!(phone_number) do
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "provider-phone:" <> phone_number
    ])
  end

  defp binding!(desired, tenant_id, except \\ nil) do
    phone_number = desired["phone_number"]
    lock_phone!(phone_number)

    if Repo.exists?(
         from(n in Number, where: n.phone_number == ^phone_number and n.tenant_id != ^tenant_id)
       ),
       do: Repo.rollback(:provider_binding_forbidden)

    query = unresolved_phone_query(phone_number)
    query = if except, do: where(query, [c], c.id != ^except), else: query
    if Repo.exists?(query), do: Repo.rollback(:telephony_outcome_unknown)
  end

  defp command!(id, tenant_id) do
    case Repo.one(
           from(c in ProvisioningCommand,
             where: c.id == ^id and c.tenant_id == ^tenant_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> Repo.rollback(:not_found)
      command -> command
    end
  end

  defp lease!(command, mode) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires = DateTime.add(now(), @lease_seconds, :second)

    command =
      change!(command, %{lease_hash: :crypto.hash(:sha256, token), lease_expires_at: expires})

    request = %ProvisioningRequest{
      command_id: command.id,
      tenant_id: command.tenant_id,
      lease_token: token,
      lease_expires_at: expires,
      version: command.version,
      mode: mode,
      phone_number: command.desired["phone_number"],
      inbound_trunk_id: command.desired["inbound_trunk_id"],
      outbound_trunk_id: command.desired["outbound_trunk_id"],
      dispatch_rule_id: command.snapshot["dispatch_rule_id"],
      effect_consumed: command.effect_consumed
    }

    {command, request}
  end

  defp require_lease!(command, request) do
    expected_mode =
      %{inspecting: :inspect, applying: :apply, reconciling: :reconcile}[command.status]

    if request.tenant_id != command.tenant_id or request.mode != expected_mode or
         request.phone_number != command.desired["phone_number"] or
         request.inbound_trunk_id != command.desired["inbound_trunk_id"] or
         request.outbound_trunk_id != command.desired["outbound_trunk_id"] or
         request.dispatch_rule_id != command.snapshot["dispatch_rule_id"] or
         request.lease_expires_at != command.lease_expires_at or
         not is_binary(request.lease_token),
       do: Repo.rollback(:telephony_lease_expired)

    digest = :crypto.hash(:sha256, request.lease_token)

    if command.version != request.version or not lease_active?(command) or
         not is_binary(command.lease_hash) or not :crypto.hash_equals(command.lease_hash, digest),
       do: Repo.rollback(:telephony_lease_expired)
  end

  defp lease_active?(%{lease_expires_at: %DateTime{} = expiry}),
    do: DateTime.compare(expiry, now()) == :gt

  defp lease_active?(_), do: false

  defp desired(attrs) do
    parameters = Map.new(@fields, &{&1, value(attrs, String.to_existing_atom(&1))})

    changeset =
      Number.changeset(%Number{}, Map.put(parameters, "tenant_id", Ecto.UUID.generate()))

    if changeset.valid?, do: {:ok, parameters}, else: {:error, validation_error(changeset)}
  end

  defp normalize_result({:ok, snapshot}, command) when is_map(snapshot) do
    snapshot = Map.new(snapshot, fn {key, value} -> {to_string(key), value} end)

    if snapshot["phone_number"] == command.desired["phone_number"] and
         snapshot["inbound_trunk_id"] == command.desired["inbound_trunk_id"] and
         snapshot["outbound_trunk_id"] == command.desired["outbound_trunk_id"] and
         is_boolean(snapshot["dispatch_ready"]) and fresh_snapshot?(snapshot) and
         ((snapshot["dispatch_ready"] == false and snapshot["dispatch_rule_id"] == nil) or
            valid_provider_id?(snapshot["dispatch_rule_id"])) do
      {:ok,
       Map.take(
         snapshot,
         ~w(phone_number inbound_trunk_id outbound_trunk_id dispatch_ready dispatch_rule_id observed_at)
       )}
    else
      {:error, :invalid_provider_projection}
    end
  end

  defp normalize_result(_, _), do: {:error, :provider_unavailable}

  defp fresh_snapshot?(snapshot) do
    with timestamp when is_binary(timestamp) <- snapshot["observed_at"],
         {:ok, time, _} <- DateTime.from_iso8601(timestamp) do
      difference = DateTime.diff(now(), time, :second)
      difference in 0..60
    else
      _ -> false
    end
  end

  defp view(command) do
    status =
      if command.status in [:inspecting, :applying, :reconciling] and not lease_active?(command),
        do: if(command.effect_consumed, do: :unknown, else: :failed),
        else: command.status

    %{
      id: command.id,
      request_id: command.request_id,
      status: Atom.to_string(status),
      version: command.version,
      assignment_version: command.assignment_version,
      desired: command.desired,
      dispatch_ready: command.snapshot["dispatch_ready"] == true,
      dispatch_rule_id: command.snapshot["dispatch_rule_id"],
      observed_at: command.snapshot["observed_at"],
      failure_reason: command.failure_reason,
      effect_in_progress: lease_active?(command) and command.status in [:applying, :reconciling]
    }
  end

  defp change!(command, attrs), do: command |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp audit!(command, grant, action, reason) do
    metadata = %{
      command_id: command.id,
      status: Atom.to_string(command.status),
      version: command.version
    }

    metadata = if reason, do: Map.put(metadata, :reason, reason), else: metadata

    case Audit.record(%{
           tenant_id: command.tenant_id,
           actor_user_id: grant.user_id,
           action: action,
           resource_type: "telephony_provisioning",
           resource_id: command.id,
           metadata: metadata
         }) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:audit_failed)
    end
  end

  defp safe_failure({:error, reason})
       when reason in [
              :provider_binding_forbidden,
              :provider_number_mismatch,
              :provider_dispatch_conflict,
              :provider_inspection_incomplete,
              :provider_unavailable,
              :telephony_lease_expired
            ],
       do: Atom.to_string(reason)

  defp safe_failure(_), do: "provider_outcome_unknown"

  defp valid_provider_id?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9_-]{2,200}$/, value)

  defp reason(attrs),
    do:
      if(
        is_binary(value(attrs, :reason)) and
          String.length(String.trim(value(attrs, :reason))) in 3..500,
        do: :ok,
        else: {:error, :reason_required}
      )

  defp uuid(value), do: case(Ecto.UUID.cast(value)) do
    {:ok, id} -> {:ok, id}
    _ -> {:error, :invalid_provisioning_request}
  end

  defp version(value, zero?) when is_integer(value),
    do:
      if(value >= if(zero?, do: 0, else: 1),
        do: {:ok, value},
        else: {:error, :invalid_provisioning_request}
      )

  defp version(_, _), do: {:error, :invalid_provisioning_request}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now()
  defp transaction(fun), do: Repo.transaction(fun, timeout: 10_000)

  defp validation_error(changeset) do
    {:ok, error} = ValidationError.from(changeset)
    error
  end
end
