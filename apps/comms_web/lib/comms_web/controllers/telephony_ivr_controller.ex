defmodule CommsWeb.TelephonyIvrController do
  use CommsWeb, :controller
  alias CommsCore.Telephony
  plug(CommsWeb.Plugs.RequireSecureTransport)
  plug(:no_store)

  def config(conn, _params) do
    with {:ok, configuration} <- Telephony.ivr_config(conn.assigns.current_subject),
         do: json(conn, %{data: configuration})
  end

  def save(conn, params) do
    with {:ok, menu} <- Telephony.save_ivr(params, conn.assigns.current_subject),
         do: json(conn, %{data: menu})
  end

  def agent_state(conn, _params) do
    with {:ok, state} <- Telephony.agent_queue_state(conn.assigns.current_subject),
         do: json(conn, %{data: state})
  end

  def set_agent_state(conn, params) do
    with {:ok, state} <- Telephony.set_agent_queue_state(params, conn.assigns.current_subject),
         do: json(conn, %{data: state})
  end

  def supervisor(conn, _params) do
    with {:ok, snapshot} <- Telephony.queue_supervisor_snapshot(conn.assigns.current_subject),
         do: json(conn, %{data: snapshot})
  end

  defp no_store(conn, _options), do: put_resp_header(conn, "cache-control", "no-store")
end
