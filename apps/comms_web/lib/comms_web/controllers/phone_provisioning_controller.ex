defmodule CommsWeb.PhoneProvisioningController do
  use CommsWeb, :controller
  import Kernel, except: [inspect: 2]
  alias CommsCore.Telephony
  alias CommsCore.Telephony.ProvisioningPort
  plug(:no_store)

  plug(
    CommsWeb.Plugs.RequireSecureTransport
    when action in [:inspect, :apply_configuration, :reconcile]
  )

  def index(conn, _params) do
    with {:ok, state} <- Telephony.phone_provisioning_state(conn.assigns.current_subject),
         do: json(conn, %{data: state})
  end

  def inspect(conn, params) do
    with {:ok, {view, request}} <-
           Telephony.inspect_phone_provisioning(params, conn.assigns.current_subject) do
      complete(conn, view, request, :inspect)
    end
  end

  def apply_configuration(conn, %{"id" => id} = params) do
    with {:ok, {view, request}} <-
           Telephony.apply_phone_provisioning(id, params, conn.assigns.current_subject) do
      complete(conn, view, request, :apply)
    end
  end

  def reconcile(conn, %{"id" => id} = params) do
    with {:ok, {view, request}} <-
           Telephony.reconcile_phone_provisioning(id, params, conn.assigns.current_subject) do
      complete(conn, view, request, :inspect)
    end
  end

  defp complete(conn, view, nil, _mode), do: json(conn, %{data: view})

  defp complete(conn, _view, request, mode) do
    result =
      if mode == :apply,
        do: ProvisioningPort.apply(request),
        else: ProvisioningPort.inspect(request)

    with {:ok, view} <-
           Telephony.complete_phone_provisioning(request, result, conn.assigns.current_subject),
         do: json(conn, %{data: view})
  end

  defp no_store(conn, _), do: put_resp_header(conn, "cache-control", "no-store")
end
