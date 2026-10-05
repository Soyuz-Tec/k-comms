defmodule CommsCore.Administration.WorkspaceDomains do
  @moduledoc false
  import Ecto.Query

  alias CommsCore.Administration.{
    DiscoveryView,
    DomainClaimView,
    DomainGovernanceFenceQuery,
    DomainIdentityAuthorization,
    DomainNames,
    DomainTXTQuery,
    DomainTXTResolver,
    DomainUserErasureCommand,
    DomainUserErasureReceipt,
    Tenant,
    WorkspaceDomainClaim,
    WorkspaceDomainGovernancePort,
    WorkspaceDomainIdentityPort
  }

  alias CommsCore.{Audit, Repo}
  @budget_ms 15_000
  @maximum_claims 8
  @challenge_ttl 1800
  @proof_ttl 7 * 24 * 60 * 60
  @txt_prefix "k-comms-workspace-verification="

  @spec list(map()) :: {:ok, [DomainClaimView.t()]} | {:error, atom()}
  def list(subject) do
    transaction(subject, fn deadline ->
      tenant_id = value(subject, :tenant_id)

      claims =
        Repo.all(
          from(claim in WorkspaceDomainClaim,
            where: claim.tenant_id == ^tenant_id,
            order_by: [asc: claim.domain],
            limit: @maximum_claims
          )
        )

      authorize!(subject, deadline)
      Enum.map(claims, &project/1)
    end)
  end

  @spec create(map(), map()) :: {:ok, DomainClaimView.t()} | {:error, atom()}
  def create(attrs, subject) when is_map(attrs) do
    with :ok <- allowed_attrs(attrs, ~w(domain discovery_enabled version)),
         {:ok, domain} <- canonical_domain(value(attrs, :domain)),
         {:ok, false_or_true} <- discovery_enabled(attrs, false),
         :ok <- expected_creation_version(attrs) do
      transaction(subject, fn deadline ->
        tenant_id = value(subject, :tenant_id)
        lock_domain!(domain, deadline)

        count =
          Repo.aggregate(
            from(c in WorkspaceDomainClaim, where: c.tenant_id == ^tenant_id),
            :count
          )

        if count >= @maximum_claims, do: Repo.rollback(:domain_limit_reached)

        if Repo.exists?(
             from(c in WorkspaceDomainClaim,
               where: c.tenant_id == ^tenant_id and c.domain == ^domain
             )
           ),
           do: Repo.rollback(:domain_already_claimed)

        timestamp = now()

        claim =
          %WorkspaceDomainClaim{}
          |> WorkspaceDomainClaim.changeset(%{
            tenant_id: tenant_id,
            domain: domain,
            challenge_actor_user_id: value(subject, :user_id),
            challenge_token: challenge_token(),
            challenge_expires_at: DateTime.add(timestamp, @challenge_ttl, :second),
            discovery_enabled: false_or_true,
            status: :pending,
            version: 1
          })
          |> insert!()

        audit!(subject, "workspace_domain.created", claim)
        authorize!(subject, deadline)
        project(claim)
      end)
    end
  end

  def create(_attrs, _subject), do: {:error, :invalid_workspace_domain}

  @spec renew(binary(), map(), map()) :: {:ok, DomainClaimView.t()} | {:error, atom()}
  def renew(id, attrs, subject) do
    mutate(id, attrs, subject, ~w(id version), fn claim, deadline ->
      timestamp = now()

      updated =
        update!(claim, %{
          challenge_actor_user_id: value(subject, :user_id),
          challenge_token: challenge_token(),
          challenge_expires_at: DateTime.add(timestamp, @challenge_ttl, :second)
        })

      audit!(subject, "workspace_domain.challenge_rotated", updated)
      authorize!(subject, deadline)
      project(updated)
    end)
  end

  @spec verify(binary(), map(), map()) :: {:ok, DomainClaimView.t()} | {:error, atom()}
  def verify(id, attrs, subject) do
    mutate(id, attrs, subject, ~w(id version), fn claim, deadline ->
      if is_nil(claim.challenge_token) or
           DateTime.compare(claim.challenge_expires_at, now()) != :gt,
         do: Repo.rollback(:domain_challenge_expired)

      query = %DomainTXTQuery{
        name: challenge_name(claim.domain),
        timeout_ms: min(5000, remaining!(deadline))
      }

      records =
        case DomainTXTResolver.lookup(query) do
          {:ok, records} -> records
          {:error, reason} -> Repo.rollback(reason)
        end

      budget!(deadline)
      timestamp = now()

      if DateTime.compare(claim.challenge_expires_at, timestamp) != :gt,
        do: Repo.rollback(:domain_challenge_expired)

      unless (@txt_prefix <> claim.challenge_token) in records,
        do: Repo.rollback(:domain_proof_missing)

      expire_previous_lease!(claim.domain, timestamp)

      if Repo.exists?(
           from(other in WorkspaceDomainClaim,
             where:
               other.domain == ^claim.domain and other.status == :verified and
                 other.id != ^claim.id and other.proof_expires_at > ^timestamp
           )
         ),
         do: Repo.rollback(:domain_in_use)

      updated =
        update!(claim, %{
          status: :verified,
          verified_at: timestamp,
          proof_expires_at: DateTime.add(timestamp, @proof_ttl, :second),
          challenge_token: nil,
          challenge_actor_user_id: nil
        })

      audit!(subject, "workspace_domain.verified", updated)
      authorize!(subject, deadline)
      project(updated)
    end)
  end

  @spec update_discovery(binary(), map(), map()) ::
          {:ok, DomainClaimView.t()} | {:error, atom()}
  def update_discovery(id, attrs, subject) do
    with {:ok, enabled} <- discovery_enabled(attrs, :required) do
      mutate(id, attrs, subject, ~w(id version discovery_enabled), fn claim, deadline ->
        updated = update!(claim, %{discovery_enabled: enabled})
        audit!(subject, "workspace_domain.discovery_changed", updated)
        authorize!(subject, deadline)
        project(updated)
      end)
    end
  end

  @spec revoke(binary(), map(), map()) :: {:ok, DomainClaimView.t()} | {:error, atom()}
  def revoke(id, attrs, subject) do
    mutate(id, attrs, subject, ~w(id version), fn claim, deadline ->
      case Repo.delete(claim) do
        {:ok, _deleted} -> :ok
        {:error, _reason} -> Repo.rollback(:domain_write_failed)
      end

      audit!(subject, "workspace_domain.revoked", claim)
      authorize!(subject, deadline)
      project(%{claim | challenge_token: nil, discovery_enabled: false, status: :expired})
    end)
  end

  @spec discover(term()) :: DiscoveryView.t()
  def discover(domain_input) do
    with {:ok, domain} <- canonical_domain(domain_input),
         timestamp = now(),
         slug when is_binary(slug) <-
           Repo.one(
             from(claim in WorkspaceDomainClaim,
               join: tenant in Tenant,
               on: tenant.id == claim.tenant_id,
               where:
                 claim.domain == ^domain and claim.status == :verified and
                   claim.discovery_enabled == true and claim.proof_expires_at > ^timestamp and
                   tenant.status == :active,
               select: tenant.slug,
               limit: 1
             )
           ),
         true <- valid_slug?(slug) do
      %DiscoveryView{
        available: true,
        sign_in_path: "/sign-in?tenant_slug=" <> URI.encode_www_form(slug)
      }
    else
      _ -> %DiscoveryView{available: false, sign_in_path: nil}
    end
  end

  @spec erase_user_challenges(DomainUserErasureCommand.t()) ::
          {:ok, DomainUserErasureReceipt.t()} | {:error, atom()}
  def erase_user_challenges(%DomainUserErasureCommand{} = command) do
    if Repo.in_transaction?() do
      with {:ok, tenant_id} <- Ecto.UUID.cast(command.tenant_id),
           {:ok, user_id} <- Ecto.UUID.cast(command.user_id),
           %DateTime{} <- command.timestamp do
        {removed, _} =
          Repo.delete_all(
            from(claim in WorkspaceDomainClaim,
              where:
                claim.tenant_id == ^tenant_id and claim.challenge_actor_user_id == ^user_id and
                  (claim.status != :verified or claim.proof_expires_at <= ^command.timestamp)
            )
          )

        {detached, _} =
          Repo.update_all(
            from(claim in WorkspaceDomainClaim,
              where: claim.tenant_id == ^tenant_id and claim.challenge_actor_user_id == ^user_id
            ),
            set: [
              challenge_actor_user_id: nil,
              challenge_token: nil,
              updated_at: command.timestamp
            ],
            inc: [version: 1]
          )

        {:ok,
         %DomainUserErasureReceipt{
           removed_challenges: removed,
           detached_verified_leases: detached
         }}
      else
        _ -> {:error, :invalid_domain_erasure_command}
      end
    else
      {:error, :transaction_required}
    end
  end

  @spec retained_claim_count(module()) :: non_neg_integer()
  def retained_claim_count(repo), do: repo.aggregate(WorkspaceDomainClaim, :count)

  @spec release_fingerprint_fragment(module(), binary()) :: map()
  def release_fingerprint_fragment(repo, tenant_id) do
    %{
      workspace_domain_claims:
        repo.all(
          from(claim in WorkspaceDomainClaim,
            where: claim.tenant_id == ^tenant_id,
            select: claim.id
          )
        )
    }
  end

  @spec canonical_domain(term()) :: {:ok, binary()} | {:error, :invalid_workspace_domain}
  defdelegate canonical_domain(input), to: DomainNames, as: :canonical

  defp mutate(id, attrs, subject, allowed, operation) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         :ok <- allowed_attrs(attrs, allowed),
         {:ok, version} <- expected_version(attrs) do
      transaction(subject, fn deadline ->
        tenant_id = value(subject, :tenant_id)

        domain =
          Repo.one(
            from(claim in WorkspaceDomainClaim,
              where: claim.id == ^id and claim.tenant_id == ^tenant_id,
              select: claim.domain
            )
          ) || Repo.rollback(:not_found)

        lock_domain!(domain, deadline)

        claim =
          Repo.one(
            from(claim in WorkspaceDomainClaim,
              where: claim.id == ^id and claim.tenant_id == ^tenant_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        if claim.version != version, do: Repo.rollback(:stale_version)
        operation.(claim, deadline)
      end)
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transaction(subject, operation) when is_map(subject) do
    deadline = System.monotonic_time(:millisecond) + @budget_ms

    Repo.transaction(
      fn ->
        budget!(deadline)

        query = %DomainGovernanceFenceQuery{
          tenant_id: value(subject, :tenant_id),
          deadline: deadline
        }

        case WorkspaceDomainGovernancePort.lock_workspace_domain_fence(query) do
          {:ok, _receipt} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        authorize!(subject, deadline)
        result = operation.(deadline)
        budget!(deadline)
        result
      end,
      timeout: 20_000
    )
  end

  defp transaction(_subject, _operation), do: {:error, :forbidden}

  defp authorize!(subject, deadline) do
    budget!(deadline)
    command = %DomainIdentityAuthorization{subject: subject, deadline: deadline}

    case WorkspaceDomainIdentityPort.authorize_workspace_domain(command) do
      {:ok, grant} -> grant
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_domain!(domain, deadline) do
    budget!(deadline)

    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "workspace-domain:" <> domain
    ])

    budget!(deadline)
  end

  defp expire_previous_lease!(domain, timestamp) do
    # Mechanical expiry changes only this canonical claim's proof status, under
    # the global domain fence. No foreign tenant or user state is touched.
    Repo.update_all(
      from(claim in WorkspaceDomainClaim,
        where:
          claim.domain == ^domain and claim.status == :verified and
            claim.proof_expires_at <= ^timestamp
      ),
      set: [
        status: :expired,
        challenge_token: nil,
        challenge_actor_user_id: nil,
        updated_at: timestamp
      ],
      inc: [version: 1]
    )
  end

  defp audit!(subject, action, claim) do
    case Audit.record(%{
           tenant_id: value(subject, :tenant_id),
           actor_user_id: value(subject, :user_id),
           request_id: value(subject, :request_id),
           action: action,
           resource_type: "workspace_domain",
           resource_id: claim.id,
           metadata: %{
             domain: claim.domain,
             version: claim.version,
             discovery_enabled: claim.discovery_enabled
           }
         }) do
      {:ok, _event} -> :ok
      {:error, _reason} -> Repo.rollback(:domain_write_failed)
    end
  end

  defp update!(claim, attrs) do
    claim
    |> WorkspaceDomainClaim.changeset(Map.put(attrs, :version, claim.version + 1))
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, _reason} -> Repo.rollback(:domain_write_failed)
    end
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, claim} -> claim
      {:error, _reason} -> Repo.rollback(:domain_write_failed)
    end
  end

  defp project(claim) do
    status =
      if claim.status == :verified and DateTime.compare(claim.proof_expires_at, now()) != :gt,
        do: :expired,
        else: claim.status

    %DomainClaimView{
      id: claim.id,
      domain: claim.domain,
      version: claim.version,
      status: status,
      discovery_enabled: claim.discovery_enabled,
      challenge_name: challenge_name(claim.domain),
      challenge_value: if(claim.challenge_token, do: @txt_prefix <> claim.challenge_token),
      challenge_expires_at: claim.challenge_expires_at,
      verified_at: claim.verified_at,
      proof_expires_at: claim.proof_expires_at
    }
  end

  defp allowed_attrs(attrs, allowed) when is_map(attrs) do
    if Enum.all?(Map.keys(attrs), &(to_string(&1) in allowed)),
      do: :ok,
      else: {:error, :invalid_workspace_domain}
  end

  defp allowed_attrs(_attrs, _allowed), do: {:error, :invalid_workspace_domain}

  defp expected_creation_version(attrs) do
    if value(attrs, :version) == 0, do: :ok, else: {:error, :version_required}
  end

  defp expected_version(attrs) do
    case value(attrs, :version) do
      version when is_integer(version) and version > 0 -> {:ok, version}
      _ -> {:error, :version_required}
    end
  end

  defp discovery_enabled(attrs, default) when is_map(attrs) do
    case Map.fetch(attrs, :discovery_enabled) do
      {:ok, enabled} when is_boolean(enabled) ->
        {:ok, enabled}

      {:ok, _invalid} ->
        {:error, :invalid_workspace_domain}

      :error ->
        case Map.fetch(attrs, "discovery_enabled") do
          {:ok, enabled} when is_boolean(enabled) -> {:ok, enabled}
          {:ok, _invalid} -> {:error, :invalid_workspace_domain}
          :error when is_boolean(default) -> {:ok, default}
          :error -> {:error, :invalid_workspace_domain}
        end
    end
  end

  defp discovery_enabled(_attrs, _default), do: {:error, :invalid_workspace_domain}
  defp challenge_name(domain), do: "_k-comms." <> domain <> "."
  defp challenge_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp valid_slug?(slug),
    do: byte_size(slug) in 2..80 and Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, slug)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp remaining!(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> remaining
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp budget!(deadline) do
    timeout = Integer.to_string(remaining!(deadline)) <> "ms"

    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $1, true)",
      [timeout]
    )

    remaining!(deadline)
    :ok
  end
end
