defmodule CommsCore.Notifications do
  @behaviour CommsCore.Accounts.NotificationPort

  alias CommsCore.Accounts.{NotificationCommand, NotificationReceipt}

  alias CommsCore.Notifications.{
    AvailabilityNotifier,
    Deliveries,
    Fanout,
    IdentityLifecycle,
    InApp,
    Intents,
    Policy,
    Preferences,
    Projector,
    PushSubscriptions
  }

  @impl true
  @typedoc "Scalar values allowed across this facade boundary."
  @type public_scalar ::
          atom()
          | binary()
          | boolean()
          | integer()
          | float()
          | DateTime.t()
          | NaiveDateTime.t()
          | nil

  @typedoc "Persistence-neutral structured data with scalar leaves."
  @type public_map :: %{
          optional(atom() | binary()) =>
            public_scalar() | public_map() | [public_scalar() | public_map()]
        }

  @typedoc "Named DTOs owned by this bounded context."
  @type public_contract ::
          CommsCore.Notifications.AttemptView.t()
          | CommsCore.Notifications.Availability.t()
          | CommsCore.Notifications.Delivery.t()
          | CommsCore.Notifications.IntentView.t()
          | CommsCore.Notifications.PreferenceView.t()
          | CommsCore.Notifications.PushSubscriptionView.t()

  @type public_value :: public_scalar() | public_map() | public_contract()
  @type public_input ::
          public_value() | [public_value()] | function() | module()
  @type public_error ::
          atom()
          | CommsCore.ValidationError.t()
          | public_map()
          | {atom(), public_scalar() | public_map()}
  @type public_response ::
          public_value()
          | [public_value()]
          | {:ok, public_value() | [public_value()]}
          | {:error, public_error()}

  @spec claim_intent(binary()) :: public_response()
  @spec dismiss_in_app(binary(), public_map()) :: public_response()
  @spec enqueue_for_event(public_map()) :: public_response()
  @spec get_preferences(public_map()) :: public_response()
  @spec list_attempts(public_map(), keyword() | public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec list_intents(public_map(), keyword() | public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec list_push_subscriptions(public_map()) ::
          [public_value()] | {:ok, [public_value()]} | {:error, public_error()}
  @spec mark_all_in_app_read(public_map()) :: public_response()
  @spec mark_in_app_read(binary(), public_map()) :: public_response()
  @spec materialize_push_destination(binary(), non_neg_integer(), binary()) :: public_response()
  @spec push_config(public_map()) :: public_response()
  @spec push_status() :: public_response()
  @spec record_delivery(public_input(), public_map()) :: public_response()
  @spec record_push_provider_result(binary(), non_neg_integer(), public_map()) ::
          public_response()
  @spec register_push_subscription(public_map(), public_map()) :: public_response()
  @spec retry_intent(binary(), public_map()) :: public_response()
  @spec revoke_push_subscription(binary(), public_map()) :: public_response()
  @spec unread_count(public_map()) :: non_neg_integer()
  @spec update_preferences(public_map(), public_map()) :: public_response()

  def execute(%NotificationCommand{} = command) do
    case IdentityLifecycle.execute(command) do
      {:ok, %NotificationReceipt{} = receipt} -> {:ok, receipt}
      other -> other
    end
  end

  defdelegate get_preferences(subject), to: Preferences, as: :get
  defdelegate update_preferences(attrs, subject), to: Preferences, as: :update

  @spec list_in_app(map(), map()) ::
          {:ok,
           %{
             notifications: [CommsCore.Notifications.IntentView.t()],
             unread_count: non_neg_integer(),
             limit: pos_integer(),
             has_more: boolean(),
             next_cursor: String.t() | nil
           }}
          | {:error, :forbidden | :invalid_cursor | :invalid_notification_filter}
  def list_in_app(subject, opts \\ %{}) do
    with {:ok, result} <- InApp.list(subject, opts) do
      {:ok, %{result | notifications: Enum.map(result.notifications, &Projector.intent/1)}}
    end
  end

  defdelegate unread_count(subject), to: InApp

  def mark_in_app_read(id, subject) do
    InApp.mark_read(id, subject) |> project_result(&Projector.intent/1)
  end

  def dismiss_in_app(id, subject) do
    InApp.dismiss(id, subject) |> project_result(&Projector.intent/1)
  end

  defdelegate mark_all_in_app_read(subject), to: InApp, as: :mark_all_read

  defdelegate push_status(), to: PushSubscriptions, as: :status
  defdelegate push_config(subject), to: PushSubscriptions, as: :config

  def list_push_subscriptions(subject) do
    with {:ok, subscriptions} <- PushSubscriptions.list(subject) do
      {:ok, Enum.map(subscriptions, &Projector.push_subscription/1)}
    end
  end

  def register_push_subscription(attrs, subject) do
    with {:ok, %{subscription: subscription} = result} <-
           PushSubscriptions.register(attrs, subject) do
      {:ok, %{result | subscription: Projector.push_subscription(subscription)}}
    end
  end

  def revoke_push_subscription(id, subject) do
    PushSubscriptions.revoke(id, subject)
    |> project_result(&Projector.push_subscription/1)
  end

  defdelegate materialize_push_destination(subscription_id, version, tenant_id),
    to: PushSubscriptions,
    as: :materialize_destination

  defdelegate record_push_provider_result(subscription_id, version, result),
    to: PushSubscriptions,
    as: :record_provider_result

  defdelegate list_intents(subject, opts \\ %{}), to: Intents, as: :list
  defdelegate list_attempts(subject, opts \\ %{}), to: Deliveries

  def enqueue_for_event(event) do
    Fanout.enqueue_for_event(event, fn availability ->
      AvailabilityNotifier.notify(availability)
    end)
  end

  defdelegate create_intent(attrs), to: Intents, as: :create
  defdelegate claim_intent(id), to: Deliveries, as: :claim
  defdelegate record_delivery(intent, result), to: Deliveries, as: :record
  defdelegate retry_intent(id, subject), to: Deliveries, as: :retry

  @doc false
  @spec authorize_delivery_management(map()) ::
          :ok | {:error, :forbidden | :step_up_required}
  defdelegate authorize_delivery_management(subject), to: Policy

  @doc false
  @spec authorize_tenant_scope(map()) :: :ok | {:error, :forbidden}
  defdelegate authorize_tenant_scope(subject), to: Policy

  defp project_result({:ok, value}, projector), do: {:ok, projector.(value)}
  defp project_result({:error, _reason} = error, _projector), do: error
end
