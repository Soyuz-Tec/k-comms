defmodule CommsIntegrations.Telephony.ProvisioningLiveKit do
  @moduledoc "Bounded LiveKit SIP management pinned to protocol 1.52.1; credentials stay server-side."
  import Kernel, except: [inspect: 1, inspect: 2]
  @behaviour CommsCore.Telephony.ProvisioningPort.Contract
  alias CommsCore.Telephony
  alias CommsCore.Telephony.ProvisioningRequest
  alias CommsIntegrations.Telephony.Config
  @timeout 3_000
  @rule_limit 100
  @room_prefix "kc_tel_inbound_"

  @impl true
  def status(tenant_id) do
    enabled = management_enabled?()

    ready =
      enabled and match?({:ok, _}, Config.control_configuration()) and binding(tenant_id) != nil

    %{
      enabled: enabled,
      ready: ready,
      reason: if(ready, do: nil, else: "operator_provider_binding_required"),
      number_purchase: false,
      trunk_credentials_edit: false
    }
  end

  @impl true
  def inspect(request), do: inspect(request, &transport/5)

  def inspect(%ProvisioningRequest{} = request, requester) when is_function(requester, 5) do
    with :ok <- bound(request),
         {:ok, config} <- Config.control_configuration(),
         {:ok, inbound} <-
           rpc(
             "ListSIPInboundTrunk",
             %{trunk_ids: [request.inbound_trunk_id]},
             request,
             :read,
             config,
             requester
           ),
         :ok <- trunk(inbound, request.inbound_trunk_id, request.phone_number),
         {:ok, outbound} <-
           rpc(
             "ListSIPOutboundTrunk",
             %{trunk_ids: [request.outbound_trunk_id]},
             request,
             :read,
             config,
             requester
           ),
         :ok <- trunk(outbound, request.outbound_trunk_id, request.phone_number),
         {:ok, rules} <-
           rpc(
             "ListSIPDispatchRule",
             %{trunk_ids: [request.inbound_trunk_id], page: %{limit: @rule_limit}},
             request,
             :read,
             config,
             requester
           ),
         {:ok, dispatch} <- dispatch(rules, request) do
      {:ok, snapshot(request, dispatch)}
    else
      {:error, _} = error -> error
      _ -> {:error, :provider_unavailable}
    end
  end

  def inspect(_, _), do: {:error, :provider_binding_forbidden}

  @impl true
  def apply(request), do: apply_configuration(request, &transport/5)

  def apply_configuration(%ProvisioningRequest{mode: :apply} = request, requester) do
    # Re-inspect before consuming the one effect capability. A reused safe rule
    # needs no provider mutation. A timed-out create is never retried here.
    with {:ok, evidence} <- inspect(request, requester) do
      if evidence.dispatch_ready do
        {:ok, evidence}
      else
        with {:ok, config} <- Config.control_configuration(),
             {:ok, rule} <-
               rpc(
                 "CreateSIPDispatchRule",
                 create_body(request),
                 request,
                 :effect,
                 config,
                 requester
               ),
             true <- safe_rule?(rule, request) and rule["name"] == rule_name(request),
             true <- valid_id?(rule["sipDispatchRuleId"]) do
          {:ok, snapshot(request, rule)}
        else
          _ -> {:error, :provider_outcome_unknown}
        end
      end
    end
  end

  def apply_configuration(_, _), do: {:error, :provider_binding_forbidden}

  def create_body(request) do
    # Modern dispatch_rule wrapper; numbers restrict the called DID. The older
    # inbound_numbers field restricts caller numbers and is not a DID fence.
    %{
      dispatch_rule: %{
        name: rule_name(request),
        trunk_ids: [request.inbound_trunk_id],
        numbers: [request.phone_number],
        hide_phone_number: false,
        rule: %{
          dispatch_rule_individual: %{room_prefix: @room_prefix, pin: "", no_randomness: false}
        }
      }
    }
  end

  defp dispatch(response, request) when is_map(response) do
    # Proto JSON omits an empty repeated field. A missing items field is the
    # official empty-list representation, while a malformed present field fails.
    dispatch_items(Map.get(response, "items", []), request)
  end

  defp dispatch(_, _), do: {:error, :provider_inspection_incomplete}

  defp dispatch_items(rules, request) when is_list(rules) and length(rules) < @rule_limit do
    relevant = Enum.filter(rules, &relevant_rule?(&1, request))

    case relevant do
      [] ->
        {:ok, nil}

      [rule] ->
        reconcile_bound =
          request.mode != :reconcile or not request.effect_consumed or
            (request.dispatch_rule_id != nil and
               rule["sipDispatchRuleId"] == request.dispatch_rule_id) or
            rule["name"] == rule_name(request)

        if safe_rule?(rule, request) and reconcile_bound and valid_id?(rule["sipDispatchRuleId"]),
          do: {:ok, rule},
          else: {:error, :provider_dispatch_conflict}

      _ ->
        {:error, :provider_dispatch_conflict}
    end
  end

  defp dispatch_items(_, _), do: {:error, :provider_inspection_incomplete}

  defp relevant_rule?(rule, request) when is_map(rule) do
    trunks = Map.get(rule, "trunkIds", [])
    numbers = Map.get(rule, "numbers", [])

    if is_list(trunks) and is_list(numbers) and
         Enum.all?(trunks, &is_binary/1) and Enum.all?(numbers, &is_binary/1) do
      (trunks == [] or request.inbound_trunk_id in trunks) and
        (numbers == [] or request.phone_number in numbers)
    else
      # Unknown matching scope must not authorize creating a competing rule.
      true
    end
  end

  defp relevant_rule?(_, _), do: true

  defp safe_rule?(rule, request) when is_map(rule) do
    body = rule["rule"]
    individual = if is_map(body), do: body["dispatchRuleIndividual"], else: nil

    is_map(body) and Map.keys(body) == ["dispatchRuleIndividual"] and is_map(individual) and
      individual["roomPrefix"] == @room_prefix and
      Map.get(individual, "pin", "") == "" and Map.get(individual, "noRandomness", false) == false and
      rule["trunkIds"] == [request.inbound_trunk_id] and rule["numbers"] == [request.phone_number] and
      Map.get(rule, "inboundNumbers", []) == [] and
      Map.get(rule, "hidePhoneNumber", false) == false and
      Map.get(rule, "roomConfig", %{}) == %{} and Map.get(rule, "roomPreset", "") == ""
  end

  defp safe_rule?(_, _), do: false

  defp trunk(%{"items" => [item]}, id, number) when is_map(item) do
    if item["sipTrunkId"] == id and is_list(item["numbers"]) and number in item["numbers"],
      do: :ok,
      else: {:error, :provider_number_mismatch}
  end

  defp trunk(_, _, _), do: {:error, :provider_number_mismatch}

  defp snapshot(request, rule) do
    %{
      phone_number: request.phone_number,
      inbound_trunk_id: request.inbound_trunk_id,
      outbound_trunk_id: request.outbound_trunk_id,
      dispatch_ready: rule != nil,
      dispatch_rule_id: if(rule, do: rule["sipDispatchRuleId"], else: nil),
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp rule_name(request), do: "kcomms-phone-" <> request.command_id

  defp bound(request) do
    with true <- management_enabled?(),
         values when is_map(values) <- binding(request.tenant_id),
         true <- request.inbound_trunk_id in list(values, :inbound_trunk_ids),
         true <- request.outbound_trunk_id in list(values, :outbound_trunk_ids),
         true <- request.phone_number in list(values, :phone_numbers) do
      :ok
    else
      _ -> {:error, :provider_binding_forbidden}
    end
  end

  defp binding(tenant_id) do
    case Application.get_env(:comms_integrations, :telephony_provisioning_bindings, %{}) do
      bindings when is_map(bindings) ->
        if valid_bindings?(bindings), do: Map.get(bindings, tenant_id), else: nil

      _ ->
        nil
    end
  end

  def valid_bindings?(bindings) when is_map(bindings) and map_size(bindings) in 1..200 do
    valid =
      Enum.all?(bindings, fn {tenant, values} ->
        is_binary(tenant) and
          Regex.match?(
            ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
            tenant
          ) and is_map(values) and
          Enum.sort(Enum.map(Map.keys(values), &to_string/1)) ==
            ~w(inbound_trunk_ids outbound_trunk_ids phone_numbers) and
          Enum.all?([:inbound_trunk_ids, :outbound_trunk_ids, :phone_numbers], fn key ->
            entries = list(values, key)

            length(entries) in 1..100 and length(Enum.uniq(entries)) == length(entries) and
              Enum.all?(entries, fn value ->
                if key == :phone_numbers,
                  do: is_binary(value) and Regex.match?(~r/^\+[1-9][0-9]{7,14}$/, value),
                  else: valid_id?(value)
              end)
          end)
      end)

    owned =
      Enum.flat_map(bindings, fn {_tenant, values} ->
        if is_map(values),
          do:
            list(values, :inbound_trunk_ids) ++
              list(values, :outbound_trunk_ids) ++ list(values, :phone_numbers),
          else: []
      end)

    valid and length(Enum.uniq(owned)) == length(owned)
  end

  def valid_bindings?(_), do: false

  defp list(map, key), do: case(Map.get(map, key) || Map.get(map, Atom.to_string(key))) do
    values when is_list(values) -> values
    _ -> []
  end

  defp valid_id?(value), do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9_-]{2,200}$/, value)

  defp management_enabled?,
    do: Application.get_env(:comms_core, :telephony_provisioning_enabled, false) == true

  defp rpc(method, body, request, mode, config, requester) do
    with :ok <- bound(request),
         :ok <- Telephony.authorize_phone_provisioning_io(request, mode, __MODULE__) do
      now = System.system_time(:second)

      claims = %{
        "iss" => config.api_key,
        "nbf" => now - 2,
        "exp" => min(now + 10, DateTime.to_unix(request.lease_expires_at)),
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "sip" => %{"admin" => true}
      }

      token = sign(claims, config.api_secret)
      uri = URI.parse(config.api_url)

      headers = [
        {"authorization", "Bearer " <> token},
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ]

      url = String.trim_trailing(config.api_url, "/") <> "/twirp/livekit.SIP/" <> method

      response =
        requester.(:post, url, headers, Jason.encode!(body),
          allowed_hosts: [uri.host],
          allowed_ports: [uri.port],
          timeout_ms: @timeout,
          max_response_bytes: 65_536
        )

      case response do
        {:ok, %{status: status, body: bytes}}
        when status in 200..299 and is_binary(bytes) and byte_size(bytes) <= 65_536 ->
          case Jason.decode(bytes) do
            {:ok, map} when is_map(map) -> {:ok, map}
            _ -> {:error, :provider_unavailable}
          end

        _ ->
          {:error,
           if(mode == :effect, do: :provider_outcome_unknown, else: :provider_unavailable)}
      end
    end
  rescue
    _ -> {:error, if(mode == :effect, do: :provider_outcome_unknown, else: :provider_unavailable)}
  catch
    :exit, _ ->
      {:error, if(mode == :effect, do: :provider_outcome_unknown, else: :provider_unavailable)}
  end

  defp sign(claims, secret) do
    header = Base.url_encode64(Jason.encode!(%{alg: "HS256", typ: "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    input = header <> "." <> payload
    input <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, input), padding: false)
  end

  defp transport(method, url, headers, body, options) do
    # PinnedHttp pins DNS/TLS destinations and bounds response bytes; never follows redirects.
    CommsIntegrations.PinnedHttp.request(method, url, headers, body, options)
  end
end
