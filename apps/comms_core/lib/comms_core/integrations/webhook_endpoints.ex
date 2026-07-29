defmodule CommsCore.Integrations.WebhookEndpoints do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Audit

  alias CommsCore.Integrations.{
    Policy,
    WebhookDeliveries,
    WebhookEndpoint,
    WebhookSecrets,
    WebhookSubscription
  }

  alias CommsCore.Repo

  def list(subject) do
    with :ok <- Policy.authorize_read(subject) do
      endpoints =
        WebhookEndpoint
        |> where([endpoint], endpoint.tenant_id == ^value(subject, :tenant_id))
        |> order_by([endpoint], asc: endpoint.name)
        |> preload(:subscriptions)
        |> Repo.all()

      {:ok, endpoints}
    end
  end

  def get(id, subject) do
    with :ok <- Policy.authorize_read(subject),
         %WebhookEndpoint{} = endpoint <-
           WebhookEndpoint
           |> where(
             [endpoint],
             endpoint.id == ^id and endpoint.tenant_id == ^value(subject, :tenant_id)
           )
           |> preload(:subscriptions)
           |> Repo.one() do
      {:ok, endpoint}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def create(attrs, subject) when is_map(attrs) do
    with :ok <- Policy.authorize_manage(subject),
         {:ok, event_types} <- validate_event_types(value(attrs, :event_types)),
         secret <- WebhookSecrets.generate() do
      Repo.transaction(fn ->
        endpoint =
          %WebhookEndpoint{}
          |> WebhookEndpoint.changeset(%{
            tenant_id: value(subject, :tenant_id),
            created_by_user_id: value(subject, :user_id),
            name: value(attrs, :name),
            url: value(attrs, :url),
            status: :active,
            secret_version: 1
          })
          |> Repo.insert!()

        secret
        |> WebhookSecrets.encrypt!(endpoint, 1)
        |> then(&WebhookSecrets.insert!(endpoint, 1, &1))

        replace_subscriptions!(endpoint, event_types)

        audit!(subject, "webhook_endpoint.created", "webhook_endpoint", endpoint.id, %{
          event_types: event_types,
          host: endpoint_host(endpoint.url)
        })

        %{endpoint: Repo.preload(endpoint, :subscriptions, force: true), secret: secret}
      end)
      |> unwrap_transaction()
    end
  end

  def update(id, attrs, subject) when is_map(attrs) do
    with :ok <- Policy.authorize_manage(subject),
         {:ok, event_types} <- maybe_event_types(attrs) do
      Repo.transaction(fn ->
        endpoint = locked_endpoint!(id, subject)
        previous_url = endpoint.url
        status = normalize_status(value(attrs, :status), endpoint.status)
        disabled_at = if status == :disabled, do: endpoint.disabled_at || now(), else: nil
        requested_url = value(attrs, :url)

        destination_change? =
          status == :disabled or (is_binary(requested_url) and requested_url != previous_url)

        if destination_change? and WebhookDeliveries.active_in_progress?(endpoint) do
          Repo.rollback(:conflict)
        end

        endpoint =
          endpoint
          |> WebhookEndpoint.changeset(
            drop_nil(%{
              name: value(attrs, :name),
              url: value(attrs, :url),
              status: status,
              disabled_at: disabled_at
            })
          )
          |> Repo.update!()

        if is_list(event_types), do: replace_subscriptions!(endpoint, event_types)

        cond do
          endpoint.status == :disabled ->
            WebhookDeliveries.terminalize_endpoint!(endpoint, "endpoint_disabled")

          endpoint.url != previous_url ->
            WebhookDeliveries.terminalize_endpoint!(endpoint, "endpoint_configuration_changed")

          true ->
            :ok
        end

        audit!(subject, "webhook_endpoint.updated", "webhook_endpoint", endpoint.id, %{
          status: endpoint.status,
          host: endpoint_host(endpoint.url),
          subscriptions_changed: is_list(event_types)
        })

        Repo.preload(endpoint, :subscriptions, force: true)
      end)
      |> unwrap_transaction()
    end
  end

  def disable(id, subject), do: __MODULE__.update(id, %{status: :disabled}, subject)

  def rotate_secret(id, subject) do
    with :ok <- Policy.authorize_manage(subject),
         secret <- WebhookSecrets.generate() do
      Repo.transaction(fn ->
        endpoint = locked_endpoint!(id, subject)

        if WebhookDeliveries.active_in_progress?(endpoint) do
          Repo.rollback(:conflict)
        end

        retired_version = endpoint.secret_version
        version = retired_version + 1
        encrypted = WebhookSecrets.encrypt!(secret, endpoint, version)

        WebhookSecrets.retire_current!(endpoint)

        WebhookDeliveries.terminalize_secret_version!(
          endpoint,
          retired_version,
          "endpoint_secret_rotated"
        )

        WebhookSecrets.insert!(endpoint, version, encrypted)

        endpoint =
          endpoint
          |> WebhookEndpoint.changeset(%{secret_version: version})
          |> Repo.update!()

        audit!(subject, "webhook_endpoint.secret_rotated", "webhook_endpoint", endpoint.id, %{
          secret_version: version
        })

        %{endpoint: endpoint, secret: secret}
      end)
      |> unwrap_transaction()
    end
  end

  defp replace_subscriptions!(endpoint, event_types) do
    Repo.delete_all(
      from(subscription in WebhookSubscription, where: subscription.endpoint_id == ^endpoint.id)
    )

    Enum.each(event_types, fn event_type ->
      %WebhookSubscription{}
      |> WebhookSubscription.changeset(%{
        tenant_id: endpoint.tenant_id,
        endpoint_id: endpoint.id,
        event_type: event_type
      })
      |> Repo.insert!()
    end)
  end

  defp locked_endpoint!(id, subject) do
    Repo.one(
      from(endpoint in WebhookEndpoint,
        where: endpoint.id == ^id and endpoint.tenant_id == ^value(subject, :tenant_id),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp validate_event_types(values) when is_list(values) do
    event_types =
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      event_types == [] ->
        {:error, :webhook_event_types_required}

      length(event_types) > 50 ->
        {:error, :too_many_webhook_event_types}

      Enum.all?(event_types, &Regex.match?(~r/^[a-z][a-z0-9_.-]{2,119}$/, &1)) ->
        {:ok, event_types}

      true ->
        {:error, :invalid_webhook_event_type}
    end
  end

  defp validate_event_types(_), do: {:error, :webhook_event_types_required}

  defp maybe_event_types(attrs) do
    if Map.has_key?(attrs, :event_types) or Map.has_key?(attrs, "event_types") do
      validate_event_types(value(attrs, :event_types))
    else
      {:ok, nil}
    end
  end

  defp normalize_status(value, _current) when value in [:active, "active"], do: :active
  defp normalize_status(value, _current) when value in [:disabled, "disabled"], do: :disabled
  defp normalize_status(_, current), do: current

  defp audit!(subject, action, resource_type, resource_id, metadata) do
    Audit.record(%{
      tenant_id: value(subject, :tenant_id),
      actor_user_id: value(subject, :user_id),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      request_id: value(subject, :request_id)
    })
    |> audit_or_rollback()
  end

  defp audit_or_rollback({:ok, event}), do: event
  defp audit_or_rollback({:error, reason}), do: Repo.rollback(reason)
  defp drop_nil(map), do: Map.reject(map, fn {_key, val} -> is_nil(val) end)
  defp endpoint_host(url), do: URI.parse(url).host
  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
