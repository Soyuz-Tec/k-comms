defmodule CommsIntegrations.SynapseIdentity do
  @moduledoc "Configured Synapse authentication adapter. No endpoint receives client encryption, cross-signing private or recovery keys."
  @behaviour CommsCore.Accounts.MatrixProvisioningPort.Contract
  alias CommsCore.Accounts.{MatrixProvisioningCommand, MatrixProvisioningReceipt}
  alias CommsIntegrations.PinnedHttp

  def execute(action, %MatrixProvisioningCommand{} = command) do
    with {:ok, config} <- config(command),
         :ok <- valid_principal(command, config),
         true <-
           is_integer(command.deadline) and command.deadline > System.monotonic_time(:millisecond) do
      config = Map.put(config, :deadline, command.deadline)
      dispatch(action, command, config)
    else
      false -> {:error, :private_operation_timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(:provision, command, config) do
    path = "/_synapse/admin/v2/users/" <> segment(command.matrix_user_id)
    expected = command.tenant_id <> "/" <> command.user_id

    case request(config, :get, path, nil, config.admin_token) do
      {:ok, 200, user} ->
        if owned_user?(user, command.matrix_user_id, expected),
          do: {:ok, %MatrixProvisioningReceipt{matrix_user_id: command.matrix_user_id}},
          else: {:error, :matrix_principal_unowned}

      {:ok, 404, _} ->
        body = %{
          password: command.password,
          admin: false,
          deactivated: false,
          logout_devices: false,
          external_ids: [%{auth_provider: "k-comms", external_id: expected}]
        }

        with {:ok, status, user} when status in [200, 201] <-
               request(config, :put, path, body, config.admin_token),
             true <-
               owned_user?(user, command.matrix_user_id, expected) ||
                 {:error, :matrix_principal_unowned} do
          {:ok, %MatrixProvisioningReceipt{matrix_user_id: command.matrix_user_id}}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :matrix_provider_rejected}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :matrix_provider_rejected}
    end
  end

  defp dispatch(:login, command, config) do
    body = %{
      type: "m.login.password",
      identifier: %{type: "m.id.user", user: command.matrix_user_id},
      password: command.password,
      device_id: command.matrix_device_id,
      initial_device_display_name: "K-Comms verified session",
      refresh_token: true
    }

    with {:ok, 200, result} <- request(config, :post, "/_matrix/client/v3/login", body, nil),
         {:ok, receipt} <- login_receipt(result, command),
         :ok <- whoami(config, receipt.access_token, command) do
      {:ok, receipt}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :matrix_login_rejected}
    end
  end

  defp dispatch(:refresh, command, config) do
    with {:ok, 200, result} <-
           request(
             config,
             :post,
             "/_matrix/client/v3/refresh",
             %{refresh_token: command.refresh_token},
             nil
           ),
         {:ok, receipt} <-
           login_receipt(
             Map.merge(result, %{
               "user_id" => command.matrix_user_id,
               "device_id" => command.matrix_device_id
             }),
             command
           ),
         :ok <- whoami(config, receipt.access_token, command) do
      {:ok, receipt}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :matrix_refresh_rejected}
    end
  end

  # Native admin device deletion invalidates every access token for this exact
  # bound device, including credentials whose login ACK was lost. The follow-up
  # native device lookup must confirm absence before cleanup is accepted.
  defp dispatch(:revoke, command, config) do
    user_path = "/_synapse/admin/v2/users/" <> segment(command.matrix_user_id)

    with {:ok, 200, _} <-
           request(
             config,
             :post,
             user_path <> "/delete_devices",
             %{devices: [command.matrix_device_id]},
             config.admin_token
           ),
         {:ok, 404, _} <-
           request(
             config,
             :get,
             user_path <> "/devices/" <> segment(command.matrix_device_id),
             nil,
             config.admin_token
           ) do
      {:ok,
       %MatrixProvisioningReceipt{
         matrix_user_id: command.matrix_user_id,
         matrix_device_id: command.matrix_device_id,
         revoked?: true
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :matrix_device_cleanup_unconfirmed}
    end
  end

  defp dispatch(:upload_public_signing_keys, command, config) do
    keys = command.public_signing_keys

    with true <-
           Enum.all?(Map.values(keys), &(&1["user_id"] == command.matrix_user_id)) ||
             {:error, :matrix_principal_mismatch},
         {:ok, 200, existing} <-
           request(
             config,
             :post,
             "/_matrix/client/v3/keys/query",
             %{device_keys: %{command.matrix_user_id => []}},
             command.access_token
           ),
         :ok <- unchanged_public_identity(keys, existing, command.matrix_user_id) do
      path = "/_matrix/client/v3/keys/device_signing/upload"

      case request(config, :post, path, keys, command.access_token) do
        {:ok, 200, _} ->
          {:ok, %MatrixProvisioningReceipt{matrix_user_id: command.matrix_user_id}}

        {:ok, 401, %{"session" => session, "flows" => flows}} when is_binary(session) ->
          if Enum.any?(flows, &(&1["stages"] == ["m.login.password"])) do
            auth = %{
              type: "m.login.password",
              session: session,
              identifier: %{type: "m.id.user", user: command.matrix_user_id},
              password: command.password
            }

            case request(config, :post, path, Map.put(keys, "auth", auth), command.access_token) do
              {:ok, 200, _} ->
                {:ok, %MatrixProvisioningReceipt{matrix_user_id: command.matrix_user_id}}

              _ ->
                {:error, :matrix_signing_authentication_rejected}
            end
          else
            {:error, :matrix_signing_authentication_unsupported}
          end

        _ ->
          {:error, :matrix_signing_authentication_rejected}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :matrix_signing_identity_unconfirmed}
    end
  end

  defp unchanged_public_identity(incoming, existing, user) do
    kinds = %{
      "master_key" => "master_keys",
      "self_signing_key" => "self_signing_keys",
      "user_signing_key" => "user_signing_keys"
    }

    if Enum.all?(incoming, fn {kind, key} ->
         retained = get_in(existing, [kinds[kind], user])
         is_nil(retained) or retained["keys"] == key["keys"]
       end), do: :ok, else: {:error, :matrix_cross_signing_reset_refused}
  end

  defp login_receipt(result, command) do
    if result["user_id"] == command.matrix_user_id and
         result["device_id"] == command.matrix_device_id and is_binary(result["access_token"]) and
         is_binary(result["refresh_token"]) and is_integer(result["expires_in_ms"]) and
         result["expires_in_ms"] in 1000..180_000 do
      {:ok,
       %MatrixProvisioningReceipt{
         matrix_user_id: result["user_id"],
         matrix_device_id: result["device_id"],
         access_token: result["access_token"],
         refresh_token: result["refresh_token"],
         expires_in_ms: result["expires_in_ms"]
       }}
    else
      {:error, :matrix_short_device_lease_required}
    end
  end

  defp whoami(config, token, command) do
    case request(config, :get, "/_matrix/client/v3/account/whoami", nil, token) do
      {:ok, 200, %{"user_id" => user, "device_id" => device}}
      when user == command.matrix_user_id and device == command.matrix_device_id ->
        :ok

      _ ->
        {:error, :matrix_device_binding_unconfirmed}
    end
  end

  defp owned_user?(user, id, expected),
    do:
      user["name"] == id and user["admin"] == false and user["deactivated"] == false and
        Enum.any?(
          user["external_ids"] || [],
          &(&1 == %{"auth_provider" => "k-comms", "external_id" => expected})
        )

  defp valid_principal(command, config) do
    expected =
      "@kc_" <>
        String.replace(command.tenant_id, "-", "") <>
        "_" <> String.replace(command.user_id, "-", "") <> ":" <> config.server_name

    if command.matrix_user_id == expected, do: :ok, else: {:error, :matrix_principal_mismatch}
  end

  defp config(command) do
    case Application.get_env(:comms_integrations, :synapse_identity) do
      %{homeserver_url: url, server_name: server_name, admin_token: token} = config
      when is_binary(url) and is_binary(server_name) and is_binary(token) and byte_size(token) > 0 ->
        uri = URI.parse(url)

        if url == command.issuer and uri.scheme == "https" and is_binary(uri.host) and
             uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
             uri.path in [nil, "", "/"] and url == String.trim_trailing(url, "/") and
             Regex.match?(~r/\A[A-Za-z0-9.-]+(?::[0-9]{1,5})?\z/, server_name) and
             not Regex.match?(~r/[\x00-\x20\x7f]/u, url <> server_name <> token),
           do: {:ok, config},
           else: {:error, :matrix_provider_configuration_invalid}

      _ ->
        {:error, :matrix_provisioning_unavailable}
    end
  end

  defp request(config, method, path, body, token) do
    uri = URI.parse(config.homeserver_url)
    remaining = config.deadline - System.monotonic_time(:millisecond)

    headers =
      [{"accept", "application/json"}, {"content-type", "application/json"}] ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: [])

    opts = [
      allowed_hosts: [uri.host],
      allowed_ports: [uri.port || 443],
      timeout_ms: min(2500, max(1, remaining)),
      deadline_ms: config.deadline,
      max_response_bytes: 131_072
    ]

    if remaining <= 0 do
      {:error, :private_operation_timeout}
    else
      result =
        case PinnedHttp.request(
               method,
               String.trim_trailing(config.homeserver_url, "/") <> path,
               headers,
               if(body, do: Jason.encode!(body), else: ""),
               opts
             ) do
          {:ok, %{status: status, body: payload}} ->
            case Jason.decode(payload) do
              {:ok, result} when is_map(result) -> {:ok, status, result}
              _ -> {:error, :matrix_provider_response_invalid}
            end

          _ ->
            {:error, :matrix_provider_unavailable}
        end

      if System.monotonic_time(:millisecond) >= config.deadline,
        do: {:error, :private_operation_timeout},
        else: result
    end
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
