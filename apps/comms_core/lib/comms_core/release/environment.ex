defmodule CommsCore.Release.Environment do
  @moduledoc false

  alias CommsCore.Attachments.RestoreContext

  @restore_remap_confirmation "remap-restored-attachment-versions"
  @qualification_confirmation "local-release-qualification-tenant-v1"
  @qualification_id_pattern ~r/\A[0-9a-f]{32}\z/
  @instant_room_fingerprint_confirmation "fixed-instant-room-tenant-fingerprint-v1"
  @instant_room_tenant_slug_pattern ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @guest_rollback_capabilities MapSet.new([
                                 "guest_identity_v1",
                                 "guest_admission_expiry_worker_v1"
                               ])
  @instant_room_rollback_capabilities MapSet.new([
                                        "instant_room_lifecycle_v1",
                                        "instant_room_presence_lease_v1",
                                        "instant_room_expiry_worker_v1",
                                        "conversation_only_human_v1"
                                      ])
  @communication_rollback_capabilities MapSet.union(
                                         @guest_rollback_capabilities,
                                         @instant_room_rollback_capabilities
                                       )
  @migration_lock_timeout_default_ms 5_000
  @migration_lock_timeout_range 1_000..30_000
  @migration_statement_timeout_default_ms 300_000
  @migration_statement_timeout_range 60_000..900_000
  @release_target_identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._:@+\/-]{0,254}\z/

  @spec validate_restore_remap((String.t() -> String.t() | nil)) ::
          {:ok, RestoreContext.t()} | {:error, atom()}
  def validate_restore_remap(get_env) when is_function(get_env, 1) do
    runtime_purpose = get_env.("K_COMMS_RUNTIME_PURPOSE")
    confirmation = get_env.("K_COMMS_RESTORE_VERSION_REMAP")
    operation_id = get_env.("K_COMMS_RESTORE_OPERATION_ID")
    actor = get_env.("K_COMMS_RESTORE_ACTOR")
    reason = get_env.("K_COMMS_RESTORE_REASON")

    cond do
      runtime_purpose != "one_shot" ->
        {:error, :one_shot_runtime_required}

      confirmation != @restore_remap_confirmation ->
        {:error, :restore_remap_confirmation_required}

      not valid_uuid?(operation_id) ->
        {:error, :restore_operation_id_required}

      not safe_audit_text?(actor, 255) ->
        {:error, :restore_actor_required}

      not safe_audit_text?(reason, 500) ->
        {:error, :restore_reason_required}

      true ->
        {:ok,
         %RestoreContext{
           operation_id: operation_id,
           actor: String.trim(actor),
           reason: String.trim(reason)
         }}
    end
  end

  @spec validate_migration((String.t() -> String.t() | nil)) ::
          {:ok, %{lock_timeout_ms: pos_integer(), statement_timeout_ms: pos_integer()}}
          | {:error, atom()}
  def validate_migration(get_env) when is_function(get_env, 1) do
    with :ok <- require_one_shot(get_env),
         :ok <- require_migration_quiescence(get_env),
         {:ok, lock_timeout_ms} <-
           parse_bounded_timeout(
             get_env.("K_COMMS_MIGRATION_LOCK_TIMEOUT_MS"),
             @migration_lock_timeout_default_ms,
             @migration_lock_timeout_range,
             :migration_lock_timeout_invalid
           ),
         {:ok, statement_timeout_ms} <-
           parse_bounded_timeout(
             get_env.("K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS"),
             @migration_statement_timeout_default_ms,
             @migration_statement_timeout_range,
             :migration_statement_timeout_invalid
           ),
         :ok <- validate_timeout_order(lock_timeout_ms, statement_timeout_ms) do
      {:ok,
       %{
         lock_timeout_ms: lock_timeout_ms,
         statement_timeout_ms: statement_timeout_ms
       }}
    end
  end

  @spec validate_qualification((String.t() -> String.t() | nil)) ::
          {:ok, %{action: :create | :delete, attrs: map()}} | {:error, atom()}
  def validate_qualification(get_env) when is_function(get_env, 1) do
    with :ok <- require_one_shot(get_env),
         :ok <- require_qualification_confirmation(get_env),
         {:ok, action} <- qualification_action(get_env.("K_COMMS_QUALIFICATION_ACTION")),
         {:ok, qualification_id} <-
           qualification_id(get_env.("K_COMMS_QUALIFICATION_ID")),
         :ok <-
           require_qualification_password(
             action,
             get_env.("K_COMMS_QUALIFICATION_PASSWORD")
           ) do
      {:ok,
       %{
         action: action,
         attrs: %{
           tenant_name: "K-Comms qualification #{qualification_id}",
           tenant_slug: "k-comms-qualification-#{qualification_id}",
           display_name: "K-Comms Qualification Owner",
           email: "k-comms-qualification-owner+#{qualification_id}@example.test",
           password: get_env.("K_COMMS_QUALIFICATION_PASSWORD")
         }
       }}
    end
  end

  @spec validate_instant_room_fingerprint((String.t() -> String.t() | nil)) ::
          {:ok, %{tenant_slug: String.t()}} | {:error, atom()}
  def validate_instant_room_fingerprint(get_env) when is_function(get_env, 1) do
    with :ok <- require_one_shot(get_env),
         :ok <- require_instant_room_fingerprint_confirmation(get_env),
         {:ok, tenant_slug} <-
           validate_instant_room_fingerprint_tenant_slug(get_env.("INSTANT_ROOM_TENANT_SLUG")) do
      {:ok, %{tenant_slug: tenant_slug}}
    end
  end

  @spec validate_guest_rollback((String.t() -> String.t() | nil)) ::
          {:ok, %{capabilities: MapSet.t(String.t()), target_revision: String.t()}}
          | {:error, atom()}
  def validate_guest_rollback(get_env) when is_function(get_env, 1) do
    validate_rollback(get_env, &guest_rollback_capable?/1)
  end

  @spec validate_communication_rollback((String.t() -> String.t() | nil)) ::
          {:ok, %{capabilities: MapSet.t(String.t()), target_revision: String.t()}}
          | {:error, atom()}
  def validate_communication_rollback(get_env) when is_function(get_env, 1) do
    validate_rollback(get_env, &communication_rollback_capable?/1)
  end

  @spec guest_rollback_capable?(MapSet.t(String.t())) :: boolean()
  def guest_rollback_capable?(capabilities) do
    MapSet.subset?(@guest_rollback_capabilities, capabilities)
  end

  @spec communication_rollback_capable?(MapSet.t(String.t())) :: boolean()
  def communication_rollback_capable?(capabilities) do
    MapSet.subset?(@communication_rollback_capabilities, capabilities)
  end

  defp require_one_shot(get_env) do
    if get_env.("K_COMMS_RUNTIME_PURPOSE") == "one_shot",
      do: :ok,
      else: {:error, :one_shot_runtime_required}
  end

  defp require_qualification_confirmation(get_env) do
    if get_env.("K_COMMS_QUALIFICATION_CONFIRMATION") == @qualification_confirmation,
      do: :ok,
      else: {:error, :qualification_confirmation_required}
  end

  defp require_instant_room_fingerprint_confirmation(get_env) do
    if get_env.("K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION") ==
         @instant_room_fingerprint_confirmation,
       do: :ok,
       else: {:error, :instant_room_fingerprint_confirmation_required}
  end

  defp validate_instant_room_fingerprint_tenant_slug(value) when is_binary(value) do
    if byte_size(value) in 2..80 and Regex.match?(@instant_room_tenant_slug_pattern, value),
      do: {:ok, value},
      else: {:error, :instant_room_tenant_slug_invalid}
  end

  defp validate_instant_room_fingerprint_tenant_slug(_value),
    do: {:error, :instant_room_tenant_slug_invalid}

  defp qualification_action("create"), do: {:ok, :create}
  defp qualification_action("delete"), do: {:ok, :delete}
  defp qualification_action(_value), do: {:error, :qualification_action_invalid}

  defp qualification_id(value) when is_binary(value) do
    if Regex.match?(@qualification_id_pattern, value),
      do: {:ok, value},
      else: {:error, :qualification_id_invalid}
  end

  defp qualification_id(_value), do: {:error, :qualification_id_invalid}

  defp require_qualification_password(:delete, _password), do: :ok

  defp require_qualification_password(:create, password)
       when is_binary(password) and byte_size(password) >= 16,
       do: :ok

  defp require_qualification_password(:create, _password),
    do: {:error, :qualification_password_required}

  defp require_migration_quiescence(get_env) do
    if get_env.("K_COMMS_MIGRATION_REQUIRE_QUIESCENCE") == "true",
      do: :ok,
      else: {:error, :migration_quiescence_confirmation_required}
  end

  defp parse_bounded_timeout(nil, default, _range, _error), do: {:ok, default}
  defp parse_bounded_timeout("", default, _range, _error), do: {:ok, default}

  defp parse_bounded_timeout(value, _default, range, error) when is_binary(value) do
    case Integer.parse(value) do
      {timeout, ""} -> if(timeout in range, do: {:ok, timeout}, else: {:error, error})
      _ -> {:error, error}
    end
  end

  defp parse_bounded_timeout(_value, _default, _range, error), do: {:error, error}

  defp validate_timeout_order(lock_timeout_ms, statement_timeout_ms)
       when statement_timeout_ms > lock_timeout_ms,
       do: :ok

  defp validate_timeout_order(_lock_timeout_ms, _statement_timeout_ms),
    do: {:error, :migration_statement_timeout_must_exceed_lock_timeout}

  defp validate_rollback(get_env, compatible?)
       when is_function(get_env, 1) and is_function(compatible?, 1) do
    with :ok <- require_one_shot(get_env) do
      capabilities =
        get_env.("K_COMMS_ROLLBACK_TARGET_CAPABILITIES")
        |> to_string()
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> MapSet.new()

      target_revision = get_env.("K_COMMS_ROLLBACK_TARGET_REVISION")

      cond do
        not valid_release_target_identifier?(target_revision) ->
          {:error, :rollback_target_revision_required}

        not compatible?.(capabilities) and
            get_env.("K_COMMS_ROLLBACK_WRITES_QUIESCED") != "true" ->
          {:error, :rollback_writes_quiescence_confirmation_required}

        true ->
          {:ok,
           %{
             capabilities: capabilities,
             target_revision: target_revision
           }}
      end
    end
  end

  defp valid_release_target_identifier?(value) when is_binary(value),
    do: Regex.match?(@release_target_identifier, value)

  defp valid_release_target_identifier?(_value), do: false

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  defp safe_audit_text?(value, max) when is_binary(value) do
    value = String.trim(value)
    value != "" and byte_size(value) <= max
  end

  defp safe_audit_text?(_value, _max), do: false
end
