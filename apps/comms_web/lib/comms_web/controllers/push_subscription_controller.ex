defmodule CommsWeb.PushSubscriptionController do
  use CommsWeb, :controller

  alias CommsCore.Notifications
  alias CommsCore.Notifications.PushSubscriptionView

  def config(conn, _params) do
    with {:ok, config} <- Notifications.push_config(conn.assigns.current_subject) do
      json(conn, %{data: config})
    end
  end

  def index(conn, _params) do
    with {:ok, subscriptions} <-
           Notifications.list_push_subscriptions(conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(subscriptions, &present/1)})
    end
  end

  def create(conn, params) do
    with {:ok, %{subscription: subscription, replayed: replayed}} <-
           Notifications.register_push_subscription(params, conn.assigns.current_subject) do
      conn
      |> put_status(if(replayed, do: :ok, else: :created))
      |> json(%{data: present(subscription), replayed: replayed})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, subscription} <-
           Notifications.revoke_push_subscription(id, conn.assigns.current_subject) do
      json(conn, %{data: present(subscription)})
    end
  end

  defp present(%PushSubscriptionView{} = subscription) do
    %{
      id: subscription.id,
      device_id: subscription.device_id,
      endpoint_hint: subscription.endpoint_hint,
      status: subscription.status,
      expires_at: subscription.expires_at,
      revoked_at: subscription.revoked_at,
      stale_at: subscription.stale_at,
      inserted_at: subscription.inserted_at,
      updated_at: subscription.updated_at
    }
  end
end
