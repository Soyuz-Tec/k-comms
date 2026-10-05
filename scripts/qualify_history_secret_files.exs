# Run only by qualify_history_secret_files.py in a network-isolated container.
# Fixtures are synthetic private files mounted directly below /run/secrets.
Code.append_paths(Path.wildcard("/source/_build/test/lib/*/ebin"))

base = %{
  "DATABASE_URL" => "ecto://postgres:postgres@localhost/synthetic_config_no_database_access",
  "SECRET_KEY_BASE" => String.duplicate("s", 64),
  "K_COMMS_ROLE" => "migration-operator-role",
  "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
  "K_COMMS_INSTANCE_ID" => "history-private-file-config-fixture",
  "PUBLIC_APP_URL" => "https://comms.example.test",
  "PASSWORD_RECOVERY_SIGNING_KEY" => String.duplicate("r", 32),
  "S3_ACCESS_KEY_ID" => "synthetic-access",
  "S3_SECRET_ACCESS_KEY" => "synthetic-secret",
  "GOV_HISTORY_CURSOR_KEY" => String.duplicate("h", 32)
}

cases =
  ~w(TELEPHONY_PBX_PASSWORD_FILE OIDC_CLIENT_SECRET_FILE IDENTITY_SECRET_ENCRYPTION_KEY_FILE IDENTITY_SECRET_ENCRYPTION_KEYS_FILE IDENTITY_SECRET_ENCRYPTION_KEYS_JSON_FILE IDENTITY_BREAK_GLASS_SECRET_FILE ARTIFACT_TRANSCRIPTION_BEARER_TOKEN_FILE ARTIFACT_TRANSCRIPTION_BEARER_TOKEN_FILE)

Enum.each(base, fn {name, value} -> System.put_env(name, value) end)
read = fn -> Config.Reader.read!("/source/config/runtime.exs", env: :prod) end

results =
  for {name, index} <- Enum.with_index(cases, 1) do
    Enum.each(cases, &System.delete_env/1)
    System.put_env(name, "/run/secrets/reused-#{index}")

    try do
      read.()
      raise "File-backed history signing material reuse was accepted for #{name}"
    rescue
      error in RuntimeError ->
        unless Exception.message(error) ==
                 "GOV_HISTORY_CURSOR_KEY must use dedicated secret material",
               do: raise("Unexpected configuration result for #{name}")
    end

    System.put_env(name, "/run/secrets/independent-#{index}")

    unless read.()[:comms_core][:governance_history_cursor_key] == base["GOV_HISTORY_CURSOR_KEY"],
      do: raise("Independent file-backed material was not accepted for #{name}")

    %{field: name, reused_material: "refused", independent_material: "accepted"}
  end

Enum.each(cases, &System.delete_env/1)
System.delete_env("GOV_HISTORY_CURSOR_KEY")

unless is_nil(read.()[:comms_core][:governance_history_cursor_key]),
  do: raise("Optional history signing default changed")

unless Enum.all?([:comms_core, :comms_integrations, :comms_web], fn app ->
         app not in Enum.map(Application.started_applications(), &elem(&1, 0))
       end),
       do: raise("Configuration qualification unexpectedly started an application")

IO.puts(
  Jason.encode!(%{
    passed: true,
    cases: results,
    absent_history: "accepted",
    application_started: false,
    network: "none"
  })
)
