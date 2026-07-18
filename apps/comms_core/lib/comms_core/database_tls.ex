defmodule CommsCore.DatabaseTLS do
  @moduledoc false

  @hostname ~r/\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i

  @spec repo_options!(String.t() | nil, String.t() | nil, String.t() | nil) :: keyword()
  def repo_options!(database_ssl, ca_file, server_name)

  def repo_options!(value, _ca_file, _server_name) when value in [nil, "", "false"] do
    [ssl: false]
  end

  def repo_options!("true", ca_file, server_name) do
    ca_file = require_ca_file!(ca_file)
    server_name = require_server_name!(server_name)

    [
      ssl: true,
      ssl_opts: [
        verify: :verify_peer,
        cacertfile: ca_file,
        server_name_indication: String.to_charlist(server_name),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  def repo_options!(_value, _ca_file, _server_name) do
    raise ArgumentError, "DATABASE_SSL must be true or false"
  end

  defp require_ca_file!(value) when is_binary(value) do
    path = String.trim(value)

    if path == "" or path != value or not File.regular?(path) do
      raise ArgumentError,
            "DATABASE_SSL_CA_FILE must identify a readable PEM CA bundle when DATABASE_SSL=true"
    end

    case File.read(path) do
      {:ok, pem} ->
        if valid_ca_bundle?(pem) do
          path
        else
          raise ArgumentError,
                "DATABASE_SSL_CA_FILE must contain at least one valid PEM certificate"
        end

      {:error, _reason} ->
        raise ArgumentError,
              "DATABASE_SSL_CA_FILE must identify a readable PEM CA bundle when DATABASE_SSL=true"
    end
  end

  defp require_ca_file!(_value) do
    raise ArgumentError,
          "DATABASE_SSL_CA_FILE must identify a readable PEM CA bundle when DATABASE_SSL=true"
  end

  defp valid_ca_bundle?(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.filter(&match?({:Certificate, _, _}, &1))
    |> Enum.any?(&valid_certificate?/1)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_certificate?({:Certificate, der, _cipher_info}) do
    _ = :public_key.pkix_decode_cert(der, :otp)
    true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp require_server_name!(value) when is_binary(value) do
    server_name = String.trim(value)

    if server_name != value or not Regex.match?(@hostname, server_name) or
         ip_address?(server_name) do
      raise ArgumentError,
            "DATABASE_SSL_SERVER_NAME must be an explicit DNS hostname when DATABASE_SSL=true"
    end

    String.downcase(server_name)
  end

  defp require_server_name!(_value) do
    raise ArgumentError,
          "DATABASE_SSL_SERVER_NAME must be an explicit DNS hostname when DATABASE_SSL=true"
  end

  defp ip_address?(value) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(value)))
  end
end
