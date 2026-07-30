defmodule CommsCore.Notifications.PushSubscriptions.Lifecycle do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Notifications.PushSubscription
  alias CommsCore.Repo

  @terminal_statuses [:revoked, :expired, :stale]

  def disable_for_device(tenant_id, user_id, device_id, reason)
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) do
    disable_where(
      dynamic(
        [subscription],
        subscription.tenant_id == ^tenant_id and subscription.user_id == ^user_id and
          subscription.device_id == ^device_id
      ),
      reason
    )
  end

  def disable_for_device(_, _, _, _), do: :ok

  def disable_for_user(tenant_id, user_id, reason)
      when is_binary(tenant_id) and is_binary(user_id) do
    disable_where(
      dynamic(
        [subscription],
        subscription.tenant_id == ^tenant_id and subscription.user_id == ^user_id
      ),
      reason
    )
  end

  def disable_for_user(_, _, _), do: :ok

  def disable!(subscription, status, reason) when status in @terminal_statuses do
    timestamp = now()

    attrs =
      %{status: status, disabled_reason: String.slice(to_string(reason), 0, 120)}
      |> maybe_put(:revoked_at, status == :revoked, timestamp)
      |> maybe_put(:stale_at, status == :stale, timestamp)

    subscription
    |> PushSubscription.changeset(attrs)
    |> Repo.update!()
  end

  def expire_due(tenant_id, user_id, device_id \\ nil) do
    timestamp = now()

    PushSubscription
    |> where(
      [subscription],
      subscription.tenant_id == ^tenant_id and subscription.user_id == ^user_id and
        subscription.status == :active and not is_nil(subscription.expires_at) and
        subscription.expires_at <= ^timestamp
    )
    |> maybe_device(device_id)
    |> Repo.update_all(
      set: [status: :expired, disabled_reason: "subscription_expired", updated_at: timestamp]
    )

    :ok
  end

  defp disable_where(filter, reason) do
    timestamp = now()

    PushSubscription
    |> where(^filter)
    |> where([subscription], subscription.status == :active)
    |> Repo.update_all(
      set: [
        status: :revoked,
        revoked_at: timestamp,
        disabled_reason: String.slice(to_string(reason), 0, 120),
        updated_at: timestamp
      ]
    )

    :ok
  end

  defp maybe_device(query, nil), do: query

  defp maybe_device(query, device_id),
    do: where(query, [subscription], subscription.device_id == ^device_id)

  defp maybe_put(map, key, true, value), do: Map.put(map, key, value)
  defp maybe_put(map, _key, false, _value), do: map
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
