defmodule CommsCore.Notifications.PushSubscriptions do
  @moduledoc false

  alias CommsCore.Notifications.PushSubscriptions.{
    DeliveryMaterializer,
    Lifecycle,
    Registration
  }

  defdelegate status(), to: Registration
  defdelegate config(subject), to: Registration
  defdelegate list(subject), to: Registration
  defdelegate register(attrs, subject), to: Registration
  defdelegate revoke(id, subject), to: Registration

  defdelegate active_subscription_ids(tenant_id, user_id),
    to: DeliveryMaterializer

  defdelegate materialize_destination(subscription_id, version, tenant_id),
    to: DeliveryMaterializer

  defdelegate record_provider_result(subscription_id, version, result),
    to: DeliveryMaterializer

  def disable_for_device(
        tenant_id,
        user_id,
        device_id,
        reason \\ "device_revoked"
      ),
      do: Lifecycle.disable_for_device(tenant_id, user_id, device_id, reason)

  def disable_for_user(tenant_id, user_id, reason \\ "user_revoked"),
    do: Lifecycle.disable_for_user(tenant_id, user_id, reason)
end
