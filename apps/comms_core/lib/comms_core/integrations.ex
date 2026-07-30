defmodule CommsCore.Integrations do
  alias CommsCore.Integrations.{
    Policy,
    Projector,
    WebhookDeliveries,
    WebhookEndpoints,
    WebhookSecrets
  }

  def list_endpoint_views(subject) do
    with {:ok, endpoints} <- list_endpoints(subject) do
      {:ok, Enum.map(endpoints, &Projector.endpoint/1)}
    end
  end

  def get_endpoint_view(id, subject),
    do: get_endpoint(id, subject) |> project_result(&Projector.endpoint/1)

  def create_endpoint_view(attrs, subject) do
    with {:ok, result} <- create_endpoint(attrs, subject) do
      {:ok, %{result | endpoint: Projector.endpoint(result.endpoint)}}
    end
  end

  def update_endpoint_view(id, attrs, subject),
    do: update_endpoint(id, attrs, subject) |> project_result(&Projector.endpoint/1)

  def disable_endpoint_view(id, subject),
    do: disable_endpoint(id, subject) |> project_result(&Projector.endpoint/1)

  def rotate_secret_view(id, subject) do
    with {:ok, result} <- rotate_secret(id, subject) do
      {:ok, %{result | endpoint: Projector.endpoint(result.endpoint)}}
    end
  end

  def list_delivery_views(subject, opts \\ %{}) do
    with {:ok, deliveries} <- list_deliveries(subject, opts) do
      {:ok, Enum.map(deliveries, &Projector.delivery/1)}
    end
  end

  def replay_delivery_view(id, subject),
    do: replay_delivery(id, subject) |> project_result(&Projector.delivery/1)

  def status, do: %{secret_storage: WebhookSecrets.status()}

  defdelegate list_endpoints(subject), to: WebhookEndpoints, as: :list
  defdelegate get_endpoint(id, subject), to: WebhookEndpoints, as: :get
  defdelegate create_endpoint(attrs, subject), to: WebhookEndpoints, as: :create
  defdelegate update_endpoint(id, attrs, subject), to: WebhookEndpoints, as: :update
  defdelegate disable_endpoint(id, subject), to: WebhookEndpoints, as: :disable
  defdelegate rotate_secret(id, subject), to: WebhookEndpoints

  defdelegate enqueue_for_event(event), to: WebhookDeliveries
  defdelegate create_delivery(attrs), to: WebhookDeliveries, as: :create
  defdelegate claim_delivery(id), to: WebhookDeliveries, as: :claim
  defdelegate delivery_request(claim), to: WebhookDeliveries, as: :request
  defdelegate record_delivery(claim, result), to: WebhookDeliveries, as: :record
  defdelegate list_deliveries(subject, opts \\ %{}), to: WebhookDeliveries, as: :list
  defdelegate replay_delivery(id, subject), to: WebhookDeliveries, as: :replay

  @doc false
  @spec authorize_read(map()) :: :ok | {:error, :forbidden}
  defdelegate authorize_read(subject), to: Policy

  @doc false
  @spec authorize_manage(map()) :: :ok | {:error, :forbidden | :step_up_required}
  defdelegate authorize_manage(subject), to: Policy

  defp project_result({:ok, result}, projector), do: {:ok, projector.(result)}
  defp project_result({:error, _reason} = error, _projector), do: error
end
