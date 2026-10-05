defmodule CommsWeb.NativePushController do
  use CommsWeb, :controller
  alias CommsCore.Notifications
  alias CommsCore.AudioCalls.CredentialRequest, as: ConversationCredential
  alias CommsCore.Telephony.CredentialRequest, as: PhoneCredential
  alias CommsIntegrations.Audio.{LiveKitReadiness, LiveKitToken}
  alias CommsWeb.Presenter
  plug(CommsWeb.Plugs.RequireSecureTransport)

  def config(conn, _params) do
    with {:ok, config} <- Notifications.native_push_config(conn.assigns.current_subject) do
      json(conn, %{data: config})
    end
  end

  def show(conn, _params) do
    with {:ok, registrations} <-
           Notifications.native_push_registrations(conn.assigns.current_subject) do
      json(conn, %{data: Enum.map(registrations, &present/1)})
    end
  end

  def register(conn, params) do
    with {:ok, %{registration: registration, replayed: replayed}} <-
           Notifications.register_native_push(params, conn.assigns.current_subject) do
      json(conn, %{data: present(registration), replayed: replayed})
    end
  end

  def revoke(conn, params) do
    with {:ok, registration} <-
           Notifications.revoke_native_push(params, conn.assigns.current_subject) do
      json(conn, %{data: present(registration)})
    end
  end

  def admit(conn, %{"id" => id} = params) when map_size(params) == 1 do
    subject = conn.assigns.current_subject

    issuer = fn owner, request ->
      issue(
        owner,
        request,
        conn.assigns.current_user.display_name,
        subject.user_id,
        Map.get(subject, :guest_expires_at)
      )
    end

    with :ok <- LiveKitReadiness.ensure_available(),
         {:ok, result} <- Notifications.admit_native_call_wake(id, subject, issuer) do
      call =
        case result.owner do
          "conversation" -> Presenter.audio_call(result.data)
          "telephony" -> CommsWeb.TelephonyPresenter.call(result.data)
        end

      json(conn, %{owner: result.owner, data: call, credential: result.credential})
    end
  end

  def admit(_conn, _params), do: {:error, :native_push_unavailable}

  defp issue("conversation", %ConversationCredential{} = request, name, user, expires) do
    LiveKitToken.issue(
      request.provider_room,
      request.media_kind,
      request.provider_identity,
      name,
      expires,
      %{"user_id" => user}
    )
  end

  defp issue("telephony", %PhoneCredential{} = request, name, user, _expires) do
    LiveKitToken.issue(
      request.provider_room,
      :audio,
      request.provider_identity,
      name,
      request.authorization_expires_at,
      %{"user_id" => user}
    )
  end

  defp issue(_, _, _, _, _), do: {:error, :native_push_unavailable}
  defp present(receipt), do: Map.from_struct(receipt)
end
