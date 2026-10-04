defmodule CommsWeb.TelephonyController do
  use CommsWeb, :controller

  alias CommsCore.Telephony
  alias CommsIntegrations.Audio.LiveKitToken
  alias CommsWeb.TelephonyPresenter

  plug(:no_store)

  plug(
    CommsWeb.Plugs.RequireSecureTransport
    when action in [:create, :answer, :join, :provision]
  )

  def config(conn, _params) do
    with {:ok, config} <- Telephony.config(conn.assigns.current_subject) do
      render_config(conn, config)
    end
  end

  def admin_config(conn, _params) do
    with {:ok, config} <- Telephony.admin_config(conn.assigns.current_subject) do
      render_config(conn, config)
    end
  end

  def provision(conn, params) do
    with {:ok, _number} <- Telephony.provision(params, conn.assigns.current_subject) do
      admin_config(conn, %{})
    end
  end

  def index(conn, params) do
    with {:ok, result} <- Telephony.list_calls(conn.assigns.current_subject, params) do
      json(conn, %{
        data: Enum.map(result.calls, &TelephonyPresenter.call/1),
        page: Map.take(result, [:limit, :has_more, :next_cursor])
      })
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, call} <- Telephony.get_call(id, conn.assigns.current_subject) do
      json(conn, %{data: TelephonyPresenter.call(call)})
    end
  end

  def create(conn, params) do
    subject = conn.assigns.current_subject

    with :ok <- provider_available(),
         {:ok, call, status} <- Telephony.start_outbound(params, subject),
         {:ok, call, credential} <- Telephony.join(call.id, subject, issuer(conn)) do
      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> json(%{data: TelephonyPresenter.call(call), credential: credential})
    end
  end

  def answer(conn, %{"id" => id}) do
    with :ok <- provider_available(),
         {:ok, call, credential} <-
           Telephony.answer(id, conn.assigns.current_subject, issuer(conn)) do
      with_credential(conn, call, credential)
    end
  end

  def join(conn, %{"id" => id}) do
    with :ok <- provider_available(),
         {:ok, call, credential} <-
           Telephony.join(id, conn.assigns.current_subject, issuer(conn)) do
      with_credential(conn, call, credential)
    end
  end

  def reject(conn, %{"id" => id}) do
    with {:ok, call} <- Telephony.reject(id, conn.assigns.current_subject) do
      json(conn, %{data: TelephonyPresenter.call(call)})
    end
  end

  def end_call(conn, %{"id" => id}) do
    with {:ok, call} <- Telephony.end_call(id, conn.assigns.current_subject) do
      json(conn, %{data: TelephonyPresenter.call(call)})
    end
  end

  defp with_credential(conn, call, credential) do
    json(conn, %{data: TelephonyPresenter.call(call), credential: credential})
  end

  defp no_store(conn, _options), do: put_resp_header(conn, "cache-control", "no-store")

  defp issuer(conn) do
    display_name = conn.assigns.current_user.display_name

    fn request ->
      LiveKitToken.issue(
        request.provider_room,
        :audio,
        request.provider_identity,
        display_name,
        request.authorization_expires_at
      )
    end
  end

  defp render_config(conn, config) do
    provider_ready = CommsIntegrations.Telephony.ready?()

    config =
      config
      |> Map.put(:enabled, CommsIntegrations.Telephony.enabled?())
      |> Map.put(:provider_ready, provider_ready)
      |> Map.put(:line_assigned, not is_nil(config.number))
      |> Map.update!(:configured, &(&1 and provider_ready))

    json(conn, %{data: TelephonyPresenter.config(config)})
  end

  defp provider_available do
    cond do
      not CommsIntegrations.Telephony.enabled?() -> {:error, :telephony_disabled}
      not CommsIntegrations.Telephony.ready?() -> {:error, :telephony_provider_unavailable}
      true -> :ok
    end
  end
end
