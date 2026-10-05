defmodule CommsCore.Notifications.NativePush do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Audit, Repo, RuntimePorts}
  alias CommsCore.Accounts.{AccessGrant, NativePushAuthority}
  alias CommsCore.Notifications.{NativeCallRequest, NativeCallTarget, NativeCallWake, NativeDelivery, NativePushRegistration, NativePushView, NativeWakePorts}
  alias CommsCore.Security.NativePushBox
  @registration_keys ~w(platform channel application_id environment token installation_id expected_version)
  @revoke_keys ~w(channel expected_version)
  @terminal ~w(consumed expired revoked failed)
  @budget_ms 5_000
  @max_per_user 10

  def rollback_hazards do
    %{native_push_registrations: Repo.aggregate(NativePushRegistration, :count),
      native_call_wake_intents: Repo.aggregate(NativeCallWake, :count)}
  end

  def tenant_fingerprint_fragment(repo, tenant) when is_atom(repo) and is_binary(tenant) do
    %{native_push_registrations: repo.all(from(r in NativePushRegistration, where: r.tenant_id == ^tenant, select: r.id)),
      native_call_wakes: repo.all(from(w in NativeCallWake, where: w.tenant_id == ^tenant, select: w.id))}
  end

  def config(subject) do
    with {:ok, %AccessGrant{account_type: :human}} <- Accounts.access_grant(subject) do
      {:ok, %{protocol_version: 1, enabled: enabled?(), platform_configs: safe_platforms(),
              registration_ttl_seconds: 86_400, wake_ttl_seconds: 30,
              background_device_qualification_required: true}}
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
  def registrations(subject) do
    with {:ok, %AccessGrant{account_type: :human} = grant} <- Accounts.access_grant(subject) do
      rows = Repo.all(from(r in NativePushRegistration, where: r.tenant_id == ^grant.tenant_id and
        r.user_id == ^grant.user_id and r.device_id == ^grant.device_id, order_by: r.channel))
      {:ok, Enum.map(rows, &view/1)}
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
  def register(attrs, subject) when is_map(attrs) and is_map(subject) do
    with true <- enabled?(), {:ok, input} <- normalize(attrs), :ok <- approved(input) do
      transaction(value(subject, :tenant_id), fn deadline ->
        capacity_lock!(subject)
        # The global high-entropy token fingerprint is never projected. Its
        # quota/provenance lock precedes identity locks; foreign reassignment is
        # always refused, even after revocation, without revealing another owner.
        advisory!("native-push-token:" <> Base.encode16(input.token_hash), deadline)
        authority = authority!(subject, deadline)
        current = Repo.one(from(r in NativePushRegistration, where: r.tenant_id == ^authority.tenant_id and
          r.user_id == ^authority.user_id and r.device_id == ^authority.device_id and r.channel == ^input.channel,
          lock: "FOR UPDATE"))
        conflict = Repo.one(from(r in NativePushRegistration, where: r.platform == ^input.platform and
          r.channel == ^input.channel and r.application_id == ^input.application_id and
          r.environment == ^input.environment and r.token_hash == ^input.token_hash))
        retained = if is_nil(current) && reusable_terminal?(conflict, authority, input) do
          candidate = Repo.one(from(r in NativePushRegistration, where: r.id == ^conflict.id, lock: "FOR UPDATE"))
          if reusable_terminal?(candidate, authority, input), do: candidate
        else
          current
        end
        if conflict && (is_nil(retained) || conflict.id != retained.id), do: Repo.rollback(:native_push_unavailable)
        expected = if current, do: current.version, else: 0
        if input.expected_version != expected, do: Repo.rollback(:native_push_version_conflict)
        if current && current.status == "active" && current.token_hash == input.token_hash &&
             current.session_id == authority.session_id && current.installation_id == input.installation_id &&
             current.user_version == authority.user_version && current.platform == input.platform &&
             current.application_id == input.application_id && current.environment == input.environment &&
             DateTime.compare(current.expires_at, DateTime.add(now(), 3_600, :second)) == :gt do
          %{registration: view(current), replayed: true}
        else
          ensure_capacity!(authority, retained)
          row = retained || %NativePushRegistration{id: Ecto.UUID.generate()}
          version = if retained, do: retained.version + 1, else: 1
          expiry = earliest(DateTime.add(now(), 86_400, :second), authority.expires_at)
          context = %{tenant_id: authority.tenant_id, registration_id: row.id, version: version,
                      channel: input.channel, application_id: input.application_id, environment: input.environment}
          encrypted = case NativePushBox.encrypt(input.token, context) do
            {:ok, result} -> result
            _ -> Repo.rollback(:native_push_unavailable)
          end
          if retained, do: terminate_wakes!(retained.id, "revoked")
          attrs = Map.merge(encrypted, %{tenant_id: authority.tenant_id, user_id: authority.user_id,
            device_id: authority.device_id, session_id: authority.session_id, user_version: authority.user_version,
            installation_id: input.installation_id, platform: input.platform, channel: input.channel,
            application_id: input.application_id, environment: input.environment, token_hash: input.token_hash,
            version: version, status: "active", expires_at: expiry, disabled_at: nil})
          saved = save!(NativePushRegistration.changeset(row, attrs))
          audit!(subject, "native_push.registered", saved.id, %{version: version, channel: saved.channel})
          %{registration: view(saved), replayed: false}
        end
      end)
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
  def register(_, _), do: {:error, :native_push_unavailable}

  # A fresh login may receive a new backend device while APNs keeps its token.
  # Rebind only an explicitly disabled registration of this same user and
  # installation. Neither a live registration nor foreign-user provenance is
  # transferable; the retained row/version also fences all prior wake intents.
  defp reusable_terminal?(%NativePushRegistration{} = row, authority, input) do
    row.tenant_id == authority.tenant_id && row.user_id == authority.user_id &&
      row.installation_id == input.installation_id && row.status in ["revoked", "expired", "stale"] &&
      is_nil(row.ciphertext) && is_nil(row.nonce) && is_nil(row.tag) && is_nil(row.key_id) &&
      row.platform == input.platform && row.channel == input.channel &&
      row.application_id == input.application_id && row.environment == input.environment
  end
  defp reusable_terminal?(_, _, _), do: false

  def revoke(attrs, subject) when is_map(attrs) and is_map(subject) do
    with true <- exact_keys?(attrs, @revoke_keys), channel when channel in ~w(apns_alert apns_voip fcm) <- value(attrs, :channel),
         version when is_integer(version) and version > 0 <- value(attrs, :expected_version) do
      transaction(value(subject, :tenant_id), fn deadline ->
        capacity_lock!(subject)
        authority = authority!(subject, deadline)
        row = Repo.one(from(r in NativePushRegistration, where: r.tenant_id == ^authority.tenant_id and
          r.user_id == ^authority.user_id and r.device_id == ^authority.device_id and r.channel == ^channel,
          lock: "FOR UPDATE")) || Repo.rollback(:native_push_unavailable)
        if row.version != version, do: Repo.rollback(:native_push_version_conflict)
        disabled = disable!(row, "revoked")
        audit!(subject, "native_push.revoked", row.id, %{version: row.version, channel: row.channel})
        view(disabled)
      end)
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
  def revoke(_, _), do: {:error, :native_push_unavailable}

  # Called by the durable outbox publisher. No contents from an outbox event
  # are included in a native payload; exact current call eligibility is owned
  # by the composed call adapter and checked separately for every device.
  def enqueue(%CommsCore.Outbox.Event{} = event) do
    case event_owner(event) do
      nil -> :ok
      _ when not is_map(event.payload) -> :ok
      owner ->
        if enabled?() && match?(%DateTime{}, event.inserted_at) do
          target = %NativeCallTarget{owner: owner, tenant_id: event.tenant_id,
            call_id: if(owner == "conversation", do: event.aggregate_id, else: value(event.payload, :call_id)),
            conversation_id: if(owner == "conversation", do: value(event.payload, :conversation_id), else: nil)}
          recipient_ids = case Repo.transaction(fn -> NativeWakePorts.recipients(target) end) do
            {:ok, {:ok, ids}} -> ids
            _ -> []
          end
          enqueue_page(event, owner, recipient_ids, nil)
        else
          :ok
        end
    end
  end
  def enqueue(_), do: :ok

  # Page the current eligible devices instead of loading a whole tenant/group.
  # An old outbox event never gets a new horizon when publishing is retried.
  defp enqueue_page(event, owner, recipient_ids, cursor) do
    if DateTime.compare(DateTime.add(event.inserted_at, 30, :second), now()) == :gt do
      query = from(r in NativePushRegistration, where: r.tenant_id == ^event.tenant_id and
        r.user_id in ^recipient_ids and r.status == "active" and r.expires_at > ^now(), order_by: r.id, limit: 100)
      query = if cursor, do: from(r in query, where: r.id > ^cursor), else: query
      rows = Repo.all(query)
      result = Enum.reduce_while(rows, :ok, fn registration, :ok ->
        case enqueue_one(event, owner, registration) do
          {:ok, _} -> {:cont, :ok}
          {:error, :native_push_unavailable} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      if result == :ok && length(rows) == 100,
        do: enqueue_page(event, owner, recipient_ids, List.last(rows).id), else: result
    else
      :ok
    end
  end

  defp enqueue_one(event, owner, snapshot) do
    transaction(snapshot.tenant_id, fn deadline ->
      capacity_lock!(subject(snapshot))
      authority = authority!(subject(snapshot), deadline)
      registration = registration!(snapshot.id, snapshot.version, authority)
      if not approved_row?(registration), do: Repo.rollback(:native_push_unavailable)
      call_id = if owner == "conversation", do: event.aggregate_id, else: value(event.payload, :call_id)
      conversation = if owner == "conversation", do: value(event.payload, :conversation_id), else: nil
      request = call_request(registration, owner, call_id, conversation, deadline)
      expiry = case NativeWakePorts.authorize(request) do
        {:ok, %DateTime{} = expires} -> earliest(expires, earliest(authority.expires_at, DateTime.add(event.inserted_at, 30, :second)))
        _ -> Repo.rollback(:native_push_unavailable)
      end
      if DateTime.compare(expiry, now()) != :gt, do: Repo.rollback(:native_push_unavailable)
      existing = Repo.one(from(w in NativeCallWake, where: w.registration_id == ^registration.id and
        w.registration_version == ^registration.version and w.call_id == ^call_id))
      if existing do
        existing.id
      else
        wake = save!(NativeCallWake.changeset(%NativeCallWake{}, %{tenant_id: registration.tenant_id,
          user_id: registration.user_id, device_id: registration.device_id, session_id: registration.session_id,
          registration_id: registration.id, registration_version: registration.version,
          user_version: registration.user_version, owner: owner, call_id: call_id, conversation_id: conversation,
          source_event_id: event.id, expires_at: expiry, status: "pending"}))
        worker = RuntimePorts.job_worker!(:native_call_wake)
        case %{wake_id: wake.id, registration_version: wake.registration_version} |> worker.new() |> Oban.insert() do
          {:ok, _} -> wake.id
          _ -> Repo.rollback(:native_push_job_unavailable)
        end
      end
    end)
  end

  # Persist an effect claim before any provider network I/O. A crashed/lost
  # reply remains uncertain and is never sent again by an Oban retry.
  def dispatch(id, version, caller) do
    with true <- RuntimePorts.authorized_job_worker?(:native_call_wake, caller),
         true <- enabled?(), {:ok, id} <- Ecto.UUID.cast(id),
         %NativeCallWake{} = snapshot <- Repo.get(NativeCallWake, id),
         {:ok, :claimed} <- claim(snapshot, version) do
      effect = transaction(snapshot.tenant_id, fn deadline ->
        capacity_lock!(subject(snapshot))
        authority = authority!(subject(snapshot), deadline)
        registration = registration!(snapshot.registration_id, version, authority)
        wake = wake!(id, authority)
        if wake.status != "dispatching" || wake.registration_version != version || not current?(wake),
          do: Repo.rollback(:native_push_unavailable)
        if not approved_row?(registration), do: Repo.rollback(:native_push_unavailable)
        case NativeWakePorts.authorize(call_request(wake, wake.owner, wake.call_id, wake.conversation_id, deadline)) do
          {:ok, %DateTime{}} -> :ok
          _ -> Repo.rollback(:native_push_unavailable)
        end
        token = case NativePushBox.decrypt(Map.from_struct(registration), crypto_context(registration)) do
          {:ok, bytes} -> bytes
          _ -> Repo.rollback(:native_push_unavailable)
        end
        delivery = %NativeDelivery{wake_id: wake.id, registration_id: registration.id,
          registration_version: registration.version, platform: registration.platform, channel: registration.channel,
          application_id: registration.application_id, environment: registration.environment, token: token,
          expires_at: wake.expires_at}
        remaining = min(deadline, System.monotonic_time(:millisecond) + max(DateTime.diff(wake.expires_at, now(), :millisecond), 0))
        result = NativeWakePorts.deliver(delivery, remaining)
        status = case result do :ok -> "sent"; {:error, :uncertain} -> "uncertain"; _ -> "failed" end
        save!(NativeCallWake.changeset(wake, %{status: status, completed_at: now()}))
        if result == {:error, :invalid_token}, do: disable!(registration, "stale")
        :complete
      end)
      case effect do
        {:ok, :complete} -> {:ok, :complete}
        _ -> uncertain(snapshot)
      end
    else
      {:ok, :already_claimed} -> {:ok, :complete}
      _ -> {:ok, :complete}
    end
  end

  defp claim(snapshot, version) do
    transaction(snapshot.tenant_id, fn deadline ->
      capacity_lock!(subject(snapshot))
      authority = authority!(subject(snapshot), deadline)
      _registration = registration!(snapshot.registration_id, version, authority)
      wake = wake!(snapshot.id, authority)
      if wake.registration_version != version || not current?(wake), do: Repo.rollback(:native_push_unavailable)
      if wake.status == "pending" do
        save!(NativeCallWake.changeset(wake, %{status: "dispatching", attempted_at: now()})); :claimed
      else
        :already_claimed
      end
    end)
  end

  def admit(id, subject, issuer) when is_binary(id) and is_map(subject) and is_function(issuer, 2) do
    with true <- enabled?(), {:ok, id} <- Ecto.UUID.cast(id) do
      transaction(value(subject, :tenant_id), fn deadline ->
        capacity_lock!(subject)
        authority = authority!(subject, deadline)
        # A foreign/old intent is neutral and never exposes call metadata.
        initial = Repo.one(from(w in NativeCallWake, where: w.id == ^id and w.tenant_id == ^authority.tenant_id and
          w.user_id == ^authority.user_id and w.device_id == ^authority.device_id and w.session_id == ^authority.session_id)) ||
          Repo.rollback(:native_push_unavailable)
        _registration = registration!(initial.registration_id, initial.registration_version, authority)
        wake = wake!(id, authority)
        if wake.status not in ["sent", "uncertain"] || not current?(wake) || wake.user_version != authority.user_version,
          do: Repo.rollback(:native_push_unavailable)
        request = call_request(wake, wake.owner, wake.call_id, wake.conversation_id, deadline)
        case NativeWakePorts.admit(request, subject, issuer) do
          {:ok, result} ->
            save!(NativeCallWake.changeset(wake, %{status: "consumed", consumed_at: now()}))
            Map.put(result, :owner, wake.owner)
          _ -> Repo.rollback(:native_push_unavailable)
        end
      end)
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
  def admit(_, _, _), do: {:error, :native_push_unavailable}

  # Invoked on identity transactions after current User/Device/Session locks;
  # it must not acquire the earlier governance/quota fences in reverse order.
  def disable_identity(tenant, kind, ids, erase? \\ false) do
    if not Repo.in_transaction?(), do: Repo.rollback(:transaction_required)
    filter = case kind do
      :sessions -> dynamic([r], r.tenant_id == ^tenant and r.session_id in ^ids)
      :device -> dynamic([r], r.tenant_id == ^tenant and r.device_id in ^ids)
      :user -> dynamic([r], r.tenant_id == ^tenant and r.user_id in ^ids)
    end
    rows = Repo.all(from(r in NativePushRegistration, where: ^filter, order_by: r.id, lock: "FOR UPDATE"))
    Enum.each(rows, fn row ->
      disable!(row, "revoked")
      if erase? do
        # Erasure is this owner's explicit contribution. The same-owner FK
        # remains defensive integrity, and is not the provenance of cleanup.
        Repo.delete_all(from(w in NativeCallWake, where: w.tenant_id == ^row.tenant_id and
          w.user_id == ^row.user_id and w.registration_id == ^row.id))
        Repo.delete!(row)
      end
    end)
    :ok
  end

  def reconcile(caller, args) when is_map(args) do
    if RuntimePorts.authorized_job_worker?(:native_push_reconciler, caller) &&
      Enum.all?(Map.keys(args), &(&1 == "after_id")) &&
      (is_nil(Map.get(args, "after_id")) || match?({:ok, _}, Ecto.UUID.cast(Map.get(args, "after_id")))) do
      cursor = case Map.get(args, "after_id") do
        nil -> nil
        value -> {:ok, id} = Ecto.UUID.cast(value); id
      end
      query = from(r in NativePushRegistration, where: r.status == "active", order_by: r.id, limit: 100)
      query = if cursor, do: from(r in query, where: r.id > ^cursor), else: query
      rows = Repo.all(query)
      Enum.each(rows, fn row ->
        transaction(row.tenant_id, fn deadline ->
          capacity_lock!(subject(row))
          case Accounts.lock_native_push_authority(subject(row), deadline) do
            {:ok, authority} ->
              current = Repo.one(from(r in NativePushRegistration, where: r.id == ^row.id, lock: "FOR UPDATE"))
              if current && (DateTime.compare(current.expires_at, now()) != :gt || current.user_version != authority.user_version), do: disable!(current, "expired")
            _ ->
              # The inactive authority cannot be revived; wipe retained token
              # ciphertext under the canonical tenant fence instead.
              current = Repo.one(from(r in NativePushRegistration, where: r.id == ^row.id, lock: "FOR UPDATE"))
              if current, do: disable!(current, "revoked")
          end
        end)
      end)
      if length(rows) == 100 do
        worker = RuntimePorts.job_worker!(:native_push_reconciler)
        case %{"after_id" => List.last(rows).id} |> worker.new() |> Oban.insert() do
          {:ok, _} -> :ok
          _ -> raise "native push reconciliation continuation could not be retained"
        end
      end
      Repo.update_all(from(w in NativeCallWake, where: w.status not in ^@terminal and w.expires_at <= ^now()),
        set: [status: "expired", disabled_at: now(), updated_at: now()])
      Repo.delete_all(from(w in NativeCallWake, where: w.expires_at < ^DateTime.add(now(), -86_400, :second)))
      :ok
    else
      {:error, :forbidden}
    end
  end

  def reconcile(_, _), do: {:error, :forbidden}

  defp normalize(attrs) do
    with true <- exact_keys?(attrs, @registration_keys),
         platform when platform in ["ios", "android"] <- value(attrs, :platform),
         channel when channel in ~w(apns_alert apns_voip fcm) <- value(attrs, :channel),
         app when is_binary(app) and byte_size(app) in 1..255 <- value(attrs, :application_id),
         true <- Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$/, app),
         environment when environment in ~w(sandbox production) <- value(attrs, :environment),
         {:ok, installation} <- Ecto.UUID.cast(value(attrs, :installation_id)),
         expected when is_integer(expected) and expected >= 0 <- value(attrs, :expected_version),
         token when is_binary(token) <- value(attrs, :token), true <- valid_token?(channel, token) do
      {:ok, %{platform: platform, channel: channel, application_id: app, environment: environment,
              token: token, token_hash: :crypto.hash(:sha256, token), installation_id: installation, expected_version: expected}}
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
  defp valid_token?(channel, token) when channel in ["apns_alert", "apns_voip"], do: Regex.match?(~r/^[a-f0-9]{64}$/, token)
  defp valid_token?("fcm", token), do: byte_size(token) in 20..4_096 and Regex.match?(~r/^[A-Za-z0-9_:\-]+$/, token)
  defp valid_token?(_, _), do: false
  defp exact_keys?(attrs, allowed) do
    keys = Enum.map(Map.keys(attrs), &to_string/1)
    length(keys) == length(Enum.uniq(keys)) && Enum.sort(keys) == Enum.sort(allowed)
  end
  defp approved(input) do
    if Enum.any?(safe_platforms(), fn config -> config.enabled &&
      config.platform == input.platform && config.channel == input.channel &&
      config.application_id == input.application_id && config.environment == input.environment end), do: :ok,
      else: {:error, :native_push_unavailable}
  end
  defp approved_row?(row), do: approved(Map.from_struct(row)) == :ok
  defp safe_platforms do
    Application.get_env(:comms_core, :native_push_platforms, [])
    |> Enum.filter(fn c -> is_map(c) && value(c, :platform) in ["ios", "android"] &&
      value(c, :channel) in ~w(apns_alert apns_voip fcm) && is_binary(value(c, :application_id)) &&
      value(c, :environment) in ~w(sandbox production) &&
      ((value(c, :platform) == "ios" && value(c, :channel) in ~w(apns_alert apns_voip)) ||
       (value(c, :platform) == "android" && value(c, :channel) == "fcm" && value(c, :environment) == "production")) end)
    |> Enum.map(fn c -> %{platform: value(c, :platform), channel: value(c, :channel),
      application_id: value(c, :application_id), environment: value(c, :environment),
      enabled: enabled?() && value(c, :device_qualified) == true &&
        value(c, :channel) in Map.get(NativeWakePorts.status(), :channels, [])} end)
  end
  defp enabled? do
    Application.get_env(:comms_core, :native_push_enabled, false) == true &&
      NativePushBox.status().status == :available && NativeWakePorts.status().status == :available
  end
  defp authority!(subject, deadline) do
    case Accounts.lock_native_push_authority(subject, deadline) do
      {:ok, %NativePushAuthority{} = receipt} -> receipt
      _ -> Repo.rollback(:native_push_unavailable)
    end
  end
  defp registration!(id, version, authority) do
    row = Repo.one(from(r in NativePushRegistration, where: r.id == ^id and r.tenant_id == ^authority.tenant_id and
      r.user_id == ^authority.user_id and r.device_id == ^authority.device_id and r.session_id == ^authority.session_id,
      lock: "FOR UPDATE")) || Repo.rollback(:native_push_unavailable)
    if row.status != "active" || row.version != version || row.user_version != authority.user_version ||
      DateTime.compare(row.expires_at, now()) != :gt, do: Repo.rollback(:native_push_unavailable)
    row
  end
  defp wake!(id, authority) do
    Repo.one(from(w in NativeCallWake, where: w.id == ^id and w.tenant_id == ^authority.tenant_id and
      w.user_id == ^authority.user_id and w.device_id == ^authority.device_id and w.session_id == ^authority.session_id,
      lock: "FOR UPDATE")) || Repo.rollback(:native_push_unavailable)
  end
  defp call_request(row, owner, id, conversation, deadline), do: %NativeCallRequest{owner: owner, call_id: id,
    conversation_id: conversation, tenant_id: row.tenant_id, user_id: row.user_id, device_id: row.device_id,
    session_id: row.session_id, deadline: deadline}
  defp subject(row), do: Map.take(Map.from_struct(row), [:tenant_id, :user_id, :device_id, :session_id])
  defp crypto_context(row), do: %{tenant_id: row.tenant_id, registration_id: row.id, version: row.version,
    channel: row.channel, application_id: row.application_id, environment: row.environment}
  defp current?(wake), do: is_nil(wake.consumed_at) && DateTime.compare(wake.expires_at, now()) == :gt
  defp disable!(row, status) do
    terminate_wakes!(row.id, "revoked")
    save!(NativePushRegistration.changeset(row, %{status: status, disabled_at: now(), ciphertext: nil, nonce: nil, tag: nil, key_id: nil}))
  end
  defp terminate_wakes!(id, status), do: Repo.update_all(from(w in NativeCallWake,
    where: w.registration_id == ^id and w.status not in ^@terminal), set: [status: status, disabled_at: now(), updated_at: now()])
  defp uncertain(snapshot) do
    Repo.update_all(from(w in NativeCallWake, where: w.id == ^snapshot.id and w.status == "dispatching"),
      set: [status: "uncertain", completed_at: now(), updated_at: now()])
    {:ok, :complete}
  end
  defp ensure_capacity!(authority, current) do
    count = Repo.aggregate(from(r in NativePushRegistration, where: r.tenant_id == ^authority.tenant_id and
      r.user_id == ^authority.user_id and r.status == "active" and r.expires_at > ^now()), :count)
    if count >= @max_per_user && (is_nil(current) || current.status != "active"), do: Repo.rollback(:native_push_unavailable)
  end
  defp capacity_lock!(subject), do: advisory!("native-push-quota:#{value(subject, :tenant_id)}:#{value(subject, :user_id)}", Process.get(:native_push_deadline))
  defp transaction(tenant, operation) do
    with {:ok, tenant} <- Ecto.UUID.cast(tenant) do
      deadline = System.monotonic_time(:millisecond) + @budget_ms
      Repo.transaction(fn ->
        Process.put(:native_push_deadline, deadline)
        try do
          # Exact same tenant advisory fence as Governance.TenantLock, always
          # first. No foreign governance persistence is read by Notifications.
          advisory!(tenant, deadline)
          result = operation.(deadline)
          if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:native_push_unavailable)
          result
        after
          Process.delete(:native_push_deadline)
        end
      end, timeout: @budget_ms + 1_000)
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
  defp advisory!(key, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:native_push_unavailable)
    timeout = "#{remaining}ms"
    Repo.query!("SELECT set_config('lock_timeout',$1,true), set_config('statement_timeout',$1,true)", [timeout])
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [key])
  end
  defp save!(changeset) do
    case Repo.insert_or_update(changeset) do {:ok, row} -> row; _ -> Repo.rollback(:native_push_unavailable) end
  end
  defp view(row), do: struct!(NativePushView, Map.take(Map.from_struct(row), NativePushView.__struct__() |> Map.keys() |> Enum.reject(&(&1 == :__struct__))))
  defp audit!(subject, action, id, metadata) do
    case Audit.record(%{tenant_id: value(subject, :tenant_id), actor_user_id: value(subject, :user_id),
      action: action, resource_type: "native_push_registration", resource_id: id, metadata: metadata,
      request_id: value(subject, :request_id)}) do {:ok, _} -> :ok; _ -> Repo.rollback(:native_push_unavailable) end
  end
  defp event_owner(%{event_type: "call.started.v1"}), do: "conversation"
  defp event_owner(%{event_type: "telephony.call.updated", payload: payload}) do
    if value(payload, :status) in ["ringing", :ringing], do: "telephony", else: nil
  end
  defp event_owner(_), do: nil
  defp earliest(nil, other), do: other
  defp earliest(other, nil), do: other
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_, _), do: nil
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
