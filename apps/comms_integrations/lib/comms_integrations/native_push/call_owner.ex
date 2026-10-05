defmodule CommsIntegrations.NativePush.CallOwner do
  @behaviour CommsCore.Notifications.NativeCallWakePort.Contract
  @moduledoc "Composition adapter delegates native wake eligibility and admission to the actual call owners."
  alias CommsCore.{AudioCalls, Telephony}
  alias CommsCore.Notifications.{NativeCallRequest, NativeCallTarget}

  def recipients(%NativeCallTarget{owner: "conversation", tenant_id: tenant, call_id: call, conversation_id: conversation}),
    do: AudioCalls.native_wake_recipients(tenant, call, conversation)
  def recipients(%NativeCallTarget{owner: "telephony", tenant_id: tenant, call_id: call}),
    do: Telephony.native_wake_recipients(tenant, call)
  def recipients(_), do: {:error, :native_push_unavailable}

  def authorize(%NativeCallRequest{owner: "conversation"} = request) do
    AudioCalls.native_wake_authority(request.conversation_id, request.call_id, subject(request))
  end
  def authorize(%NativeCallRequest{owner: "telephony"} = request) do
    Telephony.native_wake_authority(request.call_id, subject(request))
  end
  def authorize(_), do: {:error, :native_push_unavailable}

  def admit(%NativeCallRequest{owner: "conversation"} = request, current, issuer) do
    with true <- exact_subject?(request, current),
         {:ok, call, credential} <- AudioCalls.with_join_authorized(request.conversation_id, request.call_id, current,
           fn credential_request -> issuer.("conversation", credential_request) end) do
      {:ok, %{data: call, credential: credential}}
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
  def admit(%NativeCallRequest{owner: "telephony"} = request, current, issuer) do
    with true <- exact_subject?(request, current),
         # An incoming hint never claims the line. This runs only after the
         # user's OS answer action and uses the existing owner answer command.
         {:ok, call, credential} <- Telephony.answer(request.call_id, current,
           fn credential_request -> issuer.("telephony", credential_request) end) do
      {:ok, %{data: call, credential: credential}}
    else
      _ -> {:error, :native_push_unavailable}
    end
  end
  def admit(_, _, _), do: {:error, :native_push_unavailable}
  defp subject(request), do: Map.take(Map.from_struct(request), [:tenant_id, :user_id, :device_id, :session_id])
  defp exact_subject?(request, current), do: Enum.all?(subject(request), fn {key, expected} -> Map.get(current, key) == expected end)
end
