defmodule CommsCore.Notifications.PushSubscriptions.DeliveryMaterializer do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts
  alias CommsCore.Notifications.PushSubscription
  alias CommsCore.Notifications.PushSubscriptions.{Ciphertext, Lifecycle}
  alias CommsCore.Repo

  @max_active_subscriptions_per_user 10
  @terminal_statuses [:revoked, :expired, :stale]

  def active_subscription_ids(tenant_id, user_id)
      when is_binary(tenant_id) and is_binary(user_id) do
    Lifecycle.expire_due(tenant_id, user_id)

    candidates =
      PushSubscription
      |> where(
        [subscription],
        subscription.tenant_id == ^tenant_id and
          subscription.user_id == ^user_id and
          subscription.status == :active and
          (is_nil(subscription.expires_at) or
             subscription.expires_at > ^now())
      )
      |> order_by([subscription], asc: subscription.id)
      |> select([subscription], %{
        id: subscription.id,
        version: subscription.version,
        device_id: subscription.device_id
      })
      |> Repo.all()

    eligible_device_ids =
      candidates
      |> Enum.map(& &1.device_id)
      |> Enum.uniq()
      |> then(
        &Accounts.notification_eligible_device_ids(
          tenant_id,
          user_id,
          &1
        )
      )
      |> MapSet.new()

    candidates
    |> Enum.filter(&MapSet.member?(eligible_device_ids, &1.device_id))
    |> Enum.take(@max_active_subscriptions_per_user)
    |> Enum.map(&Map.take(&1, [:id, :version]))
  end

  def materialize_destination(subscription_id, version, tenant_id)
      when is_binary(subscription_id) and is_integer(version) and
             version > 0 and is_binary(tenant_id) do
    Repo.transaction(fn ->
      subscription =
        PushSubscription
        |> where(
          [subscription],
          subscription.id == ^subscription_id and
            subscription.tenant_id == ^tenant_id and
            subscription.version == ^version
        )
        |> Repo.one()

      case subscription do
        nil ->
          Repo.rollback(:push_subscription_stale)

        %PushSubscription{} = candidate ->
          unless identity_eligible?(candidate),
            do: Repo.rollback(:push_subscription_stale)

          case candidate do
            %PushSubscription{status: status}
            when status in @terminal_statuses ->
              Repo.rollback(terminal_error(status))

            %PushSubscription{} = active ->
              if expired?(active) do
                _ = Lifecycle.disable!(active, :expired, "subscription_expired")
                Repo.rollback(:push_subscription_expired)
              else
                destination = Ciphertext.decrypt!(active)

                case PushSubscription
                     |> where(
                       [subscription],
                       subscription.id == ^active.id and
                         subscription.version == ^version and
                         subscription.status == :active
                     )
                     |> Repo.update_all(
                       set: [
                         last_materialized_at: now(),
                         updated_at: now()
                       ]
                     ) do
                  {1, _} -> :ok
                  _ -> Repo.rollback(:push_subscription_stale)
                end

                unless delivery_eligible?(
                         active.id,
                         version,
                         tenant_id
                       ),
                       do: Repo.rollback(:push_subscription_stale)

                destination
              end
          end
      end
    end)
    |> unwrap_transaction()
  end

  def materialize_destination(_, _, _),
    do: {:error, :push_subscription_stale}

  def record_provider_result(
        subscription_id,
        version,
        {:error, :permanent, {:notification_status, status}}
      )
      when is_binary(subscription_id) and is_integer(version) and
             status in [404, 410] do
    timestamp = now()

    PushSubscription
    |> where(
      [subscription],
      subscription.id == ^subscription_id and
        subscription.version == ^version and
        subscription.status == :active
    )
    |> Repo.update_all(
      set: [
        status: :stale,
        stale_at: timestamp,
        disabled_reason: "provider_endpoint_gone",
        updated_at: timestamp
      ]
    )

    :ok
  end

  def record_provider_result(_subscription_id, _version, _result), do: :ok

  defp expired?(%PushSubscription{expires_at: nil}), do: false

  defp expired?(%PushSubscription{expires_at: expires_at}),
    do: DateTime.compare(expires_at, now()) != :gt

  defp delivery_eligible?(subscription_id, version, tenant_id) do
    subscription =
      PushSubscription
      |> where(
        [subscription],
        subscription.id == ^subscription_id and
          subscription.tenant_id == ^tenant_id and
          subscription.version == ^version and
          subscription.status == :active and
          (is_nil(subscription.expires_at) or
             subscription.expires_at > ^now())
      )
      |> Repo.one()

    match?(%PushSubscription{}, subscription) and
      identity_eligible?(subscription)
  end

  defp identity_eligible?(%PushSubscription{} = subscription) do
    Accounts.notification_eligible_device_ids(
      subscription.tenant_id,
      subscription.user_id,
      [subscription.device_id]
    ) == [subscription.device_id]
  end

  defp terminal_error(:revoked), do: :push_subscription_revoked
  defp terminal_error(:expired), do: :push_subscription_expired
  defp terminal_error(:stale), do: :push_subscription_stale

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
