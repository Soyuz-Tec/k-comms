defmodule CommsIntegrations.Audio.LiveKitReadiness do
  @moduledoc """
  Maintains a bounded, content-free readiness view of the LiveKit control plane.

  Status reads never perform provider I/O. A single background probe is
  debounced and cached; missing, stale, timed-out, or rejected checks fail
  closed without exposing provider URLs, credentials, rooms, or participants.
  """

  use GenServer

  alias CommsIntegrations.Audio.LiveKitToken

  @adapter :livekit
  @list_rooms_path "/twirp/livekit.RoomService/ListRooms"
  @request_timeout_ms 500
  @probe_timeout_ms 750
  @refresh_interval_ms 10_000
  @stale_after_ms 30_000
  @status_timeout_ms 100

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, @status_timeout_ms)
  catch
    :exit, _reason -> unavailable(:readiness_process_unavailable)
  end

  def ensure_available(server \\ __MODULE__) do
    case status(server) do
      %{status: :available} -> :ok
      _status -> {:error, :audio_provider_unavailable}
    end
  end

  @doc false
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh, @status_timeout_ms)
  catch
    :exit, _reason -> {:error, :readiness_process_unavailable}
  end

  @doc false
  def check(requester \\ &request/1) when is_function(requester, 1) do
    with {:ok, credential} <- LiveKitToken.issue_readiness(),
         {:ok, body} <- Jason.encode(%{}),
         request <-
           Finch.build(
             :post,
             String.trim_trailing(credential.api_url, "/") <> @list_rooms_path,
             [
               {"authorization", "Bearer " <> credential.token},
               {"content-type", "application/json"}
             ],
             body
           ),
         {:ok, response} <- requester.(request),
         :ok <- classify(response) do
      :ok
    else
      {:error, :audio_provider_unavailable} -> {:error, :configuration_incomplete}
      {:error, :provider_rejected} = error -> error
      _ -> {:error, :provider_unreachable}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      checked_at: nil,
      interval_ms: positive_option(opts, :interval_ms, @refresh_interval_ms),
      probe: Keyword.get(opts, :probe, &check/0),
      probe_task: nil,
      probe_timeout_ref: nil,
      result: unavailable(:probe_pending),
      stale_after_ms: positive_option(opts, :stale_after_ms, @stale_after_ms),
      timeout_ms: positive_option(opts, :timeout_ms, @probe_timeout_ms),
      timer_ref: nil
    }

    send(self(), :probe)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    if fresh?(state) do
      {:reply, state.result, state}
    else
      if is_nil(state.probe_task), do: send(self(), :probe)
      {:reply, unavailable(if(state.checked_at, do: :probe_stale, else: :probe_pending)), state}
    end
  end

  def handle_call(:refresh, _from, state) do
    state =
      state
      |> cancel_timer()
      |> cancel_probe()
      |> Map.merge(%{checked_at: nil, result: unavailable(:probe_pending)})

    send(self(), :probe)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:probe, %{probe_task: nil} = state) do
    task =
      Task.Supervisor.async_nolink(
        CommsIntegrations.TaskSupervisor,
        state.probe
      )

    timeout_ref = Process.send_after(self(), {:probe_timeout, task.ref}, state.timeout_ms)

    {:noreply,
     state
     |> cancel_timer()
     |> Map.merge(%{probe_task: task, probe_timeout_ref: timeout_ref})}
  end

  def handle_info(:probe, state), do: {:noreply, state}

  def handle_info({reference, result}, %{probe_task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])

    {:noreply,
     state
     |> cancel_probe_timeout()
     |> complete_probe(result)}
  end

  def handle_info({:probe_timeout, reference}, %{probe_task: %{ref: reference}} = state) do
    Task.shutdown(state.probe_task, :brutal_kill)

    {:noreply,
     state
     |> Map.merge(%{probe_task: nil, probe_timeout_ref: nil})
     |> complete_probe({:error, :probe_timeout})}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{probe_task: %{ref: reference}} = state
      ) do
    {:noreply,
     state
     |> cancel_probe_timeout()
     |> Map.put(:probe_task, nil)
     |> complete_probe({:error, :provider_unreachable})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp request(request) do
    Finch.request(request, CommsIntegrations.Finch,
      pool_timeout: @request_timeout_ms,
      receive_timeout: @request_timeout_ms
    )
  end

  defp classify(%Finch.Response{status: status}) when status in 200..299, do: :ok
  defp classify(%Finch.Response{}), do: {:error, :provider_rejected}
  defp classify(_response), do: {:error, :provider_unreachable}

  defp complete_probe(state, result) do
    state
    |> Map.merge(%{
      checked_at: monotonic_ms(),
      probe_task: nil,
      result: probe_result(result)
    })
    |> schedule_probe()
  end

  defp probe_result(:ok), do: %{status: :available, adapter: @adapter}
  defp probe_result({:error, reason}), do: unavailable(safe_reason(reason))
  defp probe_result(_result), do: unavailable(:provider_unreachable)

  defp safe_reason(reason)
       when reason in [
              :configuration_incomplete,
              :probe_timeout,
              :provider_rejected,
              :provider_unreachable
            ],
       do: reason

  defp safe_reason(_reason), do: :provider_unreachable

  defp unavailable(reason), do: %{status: :unavailable, adapter: @adapter, reason: reason}

  defp fresh?(%{checked_at: nil}), do: false

  defp fresh?(state),
    do: monotonic_ms() - state.checked_at <= state.stale_after_ms

  defp schedule_probe(state) do
    timer_ref = Process.send_after(self(), :probe, state.interval_ms)
    %{state | timer_ref: timer_ref}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: nil}
  end

  defp cancel_probe(%{probe_task: nil} = state), do: cancel_probe_timeout(state)

  defp cancel_probe(state) do
    Task.shutdown(state.probe_task, :brutal_kill)

    state
    |> Map.put(:probe_task, nil)
    |> cancel_probe_timeout()
  end

  defp cancel_probe_timeout(%{probe_timeout_ref: nil} = state), do: state

  defp cancel_probe_timeout(state) do
    Process.cancel_timer(state.probe_timeout_ref)
    %{state | probe_timeout_ref: nil}
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
