defmodule CommsCore.DatabaseTLSTest do
  use ExUnit.Case, async: true

  alias CommsCore.DatabaseTLS

  @ca_file Path.expand("fixtures/database-ca.crt", __DIR__)

  test "keeps TLS disabled without production database TLS inputs" do
    assert DatabaseTLS.repo_options!(nil, nil, nil) == [ssl: false]
    assert DatabaseTLS.repo_options!("false", nil, nil) == [ssl: false]
  end

  test "builds peer and hostname verification options for an explicit CA bundle" do
    assert [
             ssl: true,
             ssl_opts: [
               verify: :verify_peer,
               cacertfile: @ca_file,
               server_name_indication: ~c"postgres.internal.example",
               customize_hostname_check: [match_fun: match_fun]
             ]
           ] = DatabaseTLS.repo_options!("true", @ca_file, "Postgres.Internal.Example")

    assert is_function(match_fun, 2)
  end

  test "requires an explicit readable CA bundle when TLS is enabled" do
    assert_raise ArgumentError, ~r/DATABASE_SSL_CA_FILE/, fn ->
      DatabaseTLS.repo_options!("true", nil, "postgres.internal.example")
    end

    assert_raise ArgumentError, ~r/DATABASE_SSL_CA_FILE/, fn ->
      DatabaseTLS.repo_options!(
        "true",
        Path.join(System.tmp_dir!(), "missing-k-comms-database-ca.pem"),
        "postgres.internal.example"
      )
    end
  end

  test "rejects a readable file that is not a valid PEM certificate" do
    path = Path.join(System.tmp_dir!(), "k-comms-invalid-database-ca-#{System.unique_integer()}")
    File.write!(path, "not a certificate")
    on_exit(fn -> File.rm(path) end)

    assert_raise ArgumentError, ~r/at least one valid PEM certificate/, fn ->
      DatabaseTLS.repo_options!("true", path, "postgres.internal.example")
    end
  end

  test "requires a DNS verification hostname and rejects IP literals" do
    for server_name <- [
          nil,
          "",
          " postgres.internal.example",
          "https://postgres.example",
          "10.0.0.8"
        ] do
      assert_raise ArgumentError, ~r/DATABASE_SSL_SERVER_NAME/, fn ->
        DatabaseTLS.repo_options!("true", @ca_file, server_name)
      end
    end
  end

  test "rejects ambiguous DATABASE_SSL values instead of silently disabling TLS" do
    assert_raise ArgumentError, ~r/DATABASE_SSL must be true or false/, fn ->
      DatabaseTLS.repo_options!("TRUE", @ca_file, "postgres.internal.example")
    end
  end
end
