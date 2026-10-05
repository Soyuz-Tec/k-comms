defmodule CommsCore.ServiceAccounts.Authentication do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{Device, User}
  alias CommsCore.Administration
  alias CommsCore.Repo
  alias CommsCore.ServiceAccounts.ServiceAccount

  @dummy_id "00000000-0000-0000-0000-000000000000"
  @dummy_hash :crypto.hash(:sha256, "k-comms-service-account-dummy-secret")

  def authenticate(token, request_id \\ nil) do
    {account_id, secret} = parsed_credential(token)
    digest = :crypto.hash(:sha256, secret)
    identity = service_identity(account_id)
    expected = if identity, do: elem(identity, 0).secret_hash, else: @dummy_hash
    secret_valid = secure_equals(expected, digest)

    case identity do
      {%ServiceAccount{} = account, %User{} = user, %Device{} = device} when secret_valid ->
        with true <- active_identity?(account, user, device),
             {:ok, _tenant} <- Administration.active_tenant(account.tenant_id) do
          touch_last_used(account)

          {:ok,
           %{
             auth_type: :service,
             service_account_id: account.id,
             credential_generation: account.credential_generation,
             tenant_id: account.tenant_id,
             user_id: account.user_id,
             device_id: account.device_id,
             scopes: account.scopes,
             request_id: request_id
           }}
        else
          _ -> {:error, :invalid_service_token}
        end

      _ ->
        {:error, :invalid_service_token}
    end
  end

  def authorize(subject, required_scope),
    do: authorize(subject, required_scope, System.monotonic_time(:millisecond) + 30_000)

  # SCIM validates the request before resolving its managed identity lock set.
  # This read never retains an earlier service-User lock, even when an owner
  # caller supplied a surrounding transaction; authorize/4 is mandatory for
  # the actual write and retains the complete canonical set through commit.
  def preflight(subject, required_scope) when is_map(subject) and is_binary(required_scope) do
    with true <- value(subject, :auth_type) == :service,
         true <- required_scope in ServiceAccount.scopes(),
         {:ok, identity_key} <- service_identity_key(subject),
         %ServiceAccount{} = account <- current_service_account(identity_key),
         true <- required_scope in account.scopes,
         true <- DateTime.compare(account.expires_at, now()) == :gt do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def preflight(_, _), do: {:error, :forbidden}

  def authorize(subject, required_scope, deadline)
      when is_map(subject) and is_binary(required_scope) and is_integer(deadline),
      do: authorize(subject, required_scope, deadline, [])

  def authorize(_, _, _), do: {:error, :forbidden}

  def authorize(subject, required_scope, deadline, managed_user_ids)
      when is_map(subject) and is_binary(required_scope) and is_integer(deadline) and
             is_list(managed_user_ids) and length(managed_user_ids) <= 1 do
    with true <- value(subject, :auth_type) == :service,
         true <- required_scope in ServiceAccount.scopes(),
         {:ok, identity_key} <- service_identity_key(subject),
         :ok <- lock_transaction_identity(identity_key, deadline, managed_user_ids),
         :ok <- refresh_query_budget(deadline),
         %ServiceAccount{} = account <- current_service_account(identity_key),
         true <- required_scope in account.scopes,
         true <- DateTime.compare(account.expires_at, now()) == :gt,
         :ok <- refresh_query_budget(deadline) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(_, _, _, _), do: {:error, :forbidden}

  # A transactional writer retains credential authority through its effect.
  # Match rotation/revocation's account -> users -> service device order;
  # taking a user before the account would invert disable_account!/3's locks.
  # SCIM retains its exact managed target in the same canonical User ordering
  # used by governance. Mutation targets retain NO KEY UPDATE from their first
  # acquisition; the service actor otherwise retains its existing SHARE mode.
  # The final projection below reads the current time and credential generation
  # after any waits, rather than trusting the authenticated request snapshot.
  defp lock_transaction_identity(identity_key, deadline, managed_user_ids) do
    if Repo.in_transaction?() do
      with :ok <- refresh_query_budget(deadline),
           {:ok, _policy} <- Administration.lock_call_policy(identity_key.tenant_id),
           :ok <- refresh_query_budget(deadline),
           %ServiceAccount{} <-
             Repo.one(
               from(account in ServiceAccount,
                 where:
                   account.id == ^identity_key.service_account_id and
                     account.tenant_id == ^identity_key.tenant_id and
                     account.user_id == ^identity_key.user_id and
                     account.device_id == ^identity_key.device_id and
                     account.credential_generation == ^identity_key.credential_generation,
                 lock: "FOR SHARE"
               )
             ),
           :ok <- lock_identity_users(identity_key, managed_user_ids, deadline),
           :ok <- refresh_query_budget(deadline),
           %Device{} <-
             Repo.one(
               from(device in Device,
                 where:
                   device.id == ^identity_key.device_id and
                     device.user_id == ^identity_key.user_id and
                     device.tenant_id == ^identity_key.tenant_id,
                 lock: "FOR SHARE"
               )
             ) do
        :ok
      else
        _ -> {:error, :forbidden}
      end
    else
      :ok
    end
  end

  defp lock_identity_users(identity_key, managed_user_ids, deadline)
       when is_list(managed_user_ids) and length(managed_user_ids) <= 1 do
    user_ids = Enum.sort(Enum.uniq([identity_key.user_id | managed_user_ids]))

    if Enum.all?(user_ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      Enum.reduce_while(user_ids, :ok, fn user_id, :ok ->
        query =
          from(user in User,
            where: user.id == ^user_id and user.tenant_id == ^identity_key.tenant_id,
            order_by: [asc: user.id],
            select: user.id
          )

        query =
          if user_id in managed_user_ids,
            do: from(user in query, lock: "FOR NO KEY UPDATE"),
            else: from(user in query, lock: "FOR SHARE")

        with :ok <- refresh_query_budget(deadline),
             ^user_id <- Repo.one(query),
             :ok <- refresh_query_budget(deadline) do
          {:cont, :ok}
        else
          _ -> {:halt, {:error, :forbidden}}
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  defp lock_identity_users(_, _, _), do: {:error, :forbidden}

  defp refresh_query_budget(deadline) do
    if Repo.in_transaction?() do
      remaining = deadline - System.monotonic_time(:millisecond) - 1_000

      if remaining > 0 do
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT set_config('statement_timeout', $1, true), set_config('lock_timeout', $1, true)",
          [Integer.to_string(remaining)]
        )

        :ok
      else
        {:error, :forbidden}
      end
    else
      :ok
    end
  end

  defp current_service_account(identity_key) do
    timestamp = now()

    account =
      Repo.one(
        from(account in ServiceAccount,
          join: user in User,
          on: user.id == account.user_id and user.tenant_id == account.tenant_id,
          join: device in Device,
          on:
            device.id == account.device_id and device.user_id == account.user_id and
              device.tenant_id == account.tenant_id,
          where:
            account.id == ^identity_key.service_account_id and
              account.tenant_id == ^identity_key.tenant_id and
              account.user_id == ^identity_key.user_id and
              account.device_id == ^identity_key.device_id and
              account.credential_generation == ^identity_key.credential_generation and
              account.status == :active and account.expires_at > ^timestamp and
              user.account_type == :service and user.status == :active and
              user.role == :member and is_nil(user.platform_role) and
              is_nil(user.password_hash) and
              device.platform == "service_account" and is_nil(device.revoked_at),
          select: account
        )
      )

    case account do
      %ServiceAccount{tenant_id: tenant_id} = active_account ->
        case Administration.active_tenant(tenant_id) do
          {:ok, _tenant} -> active_account
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp service_identity_key(subject) do
    with {:ok, service_account_id} <- cast_uuid(value(subject, :service_account_id)),
         {:ok, tenant_id} <- cast_uuid(value(subject, :tenant_id)),
         {:ok, user_id} <- cast_uuid(value(subject, :user_id)),
         {:ok, device_id} <- cast_uuid(value(subject, :device_id)),
         credential_generation
         when is_integer(credential_generation) and credential_generation > 0 <-
           value(subject, :credential_generation) do
      {:ok,
       %{
         service_account_id: service_account_id,
         tenant_id: tenant_id,
         user_id: user_id,
         device_id: device_id,
         credential_generation: credential_generation
       }}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp service_identity(account_id) do
    Repo.one(
      from(account in ServiceAccount,
        join: user in User,
        on: user.id == account.user_id and user.tenant_id == account.tenant_id,
        join: device in Device,
        on:
          device.id == account.device_id and device.user_id == account.user_id and
            device.tenant_id == account.tenant_id,
        where: account.id == ^account_id,
        select: {account, user, device}
      )
    )
  end

  defp active_identity?(account, user, device) do
    account.status == :active and DateTime.compare(account.expires_at, now()) == :gt and
      user.account_type == :service and user.status == :active and is_nil(user.password_hash) and
      user.role == :member and is_nil(user.platform_role) and
      device.platform == "service_account" and is_nil(device.revoked_at)
  end

  defp touch_last_used(account) do
    timestamp = now()
    threshold = DateTime.add(timestamp, -60, :second)

    from(candidate in ServiceAccount,
      where:
        candidate.id == ^account.id and candidate.tenant_id == ^account.tenant_id and
          candidate.status == :active and
          (is_nil(candidate.last_used_at) or candidate.last_used_at < ^threshold)
    )
    |> Repo.update_all(set: [last_used_at: timestamp, updated_at: timestamp])

    :ok
  end

  defp parsed_credential(token) when is_binary(token) and byte_size(token) <= 256 do
    case String.split(token, ".", parts: 2) do
      ["kcsa_" <> id, secret] ->
        with {:ok, normalized_id} <- Ecto.UUID.cast(id),
             {:ok, decoded} <- Base.url_decode64(secret, padding: false),
             true <- byte_size(decoded) == 32 do
          {normalized_id, secret}
        else
          _ -> {@dummy_id, "invalid"}
        end

      _ ->
        {@dummy_id, "invalid"}
    end
  end

  defp parsed_credential(_), do: {@dummy_id, "invalid"}

  defp secure_equals(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp secure_equals(_, _), do: false
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
