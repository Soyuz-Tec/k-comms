defmodule CommsCore.Release.InstantRoomFingerprint do
  @moduledoc false

  alias CommsCore.{
    Accounts,
    Administration,
    AudioCalls,
    Audit,
    Conversations,
    Messaging,
    Outbox,
    Release.Environment,
    Repo
  }

  @app :comms_core
  @categories [
    :users,
    :sessions,
    :devices,
    :conversations,
    :memberships,
    :messages,
    :guest_links,
    :guest_admissions,
    :ephemeral_rooms,
    :ephemeral_presence_leases,
    :ephemeral_join_receipts,
    :audit_events,
    :outbox_events,
    :calls,
    :call_participants
  ]

  def run do
    with {:ok, context} <- Environment.validate_instant_room_fingerprint(&System.get_env/1) do
      load_app()

      {:ok, report, _started_apps} =
        Ecto.Migrator.with_repo(Repo, fn repo ->
          fingerprint(repo, context.tenant_slug)
        end)

      IO.puts(format(report))
      :ok
    else
      {:error, reason} ->
        raise "instant-room tenant fingerprint refused: " <>
                fingerprint_error(reason)
    end
  end

  def categories, do: @categories

  def fingerprint(repo, tenant_slug) when is_atom(repo) and is_binary(tenant_slug) do
    case Administration.release_tenant_fingerprint_id(repo, tenant_slug) do
      nil ->
        build(nil, %{})

      tenant_id ->
        fragments = [
          Accounts.release_tenant_fingerprint_fragment(repo, tenant_id),
          Conversations.release_tenant_fingerprint_fragment(repo, tenant_id),
          Messaging.release_tenant_fingerprint_fragment(repo, tenant_id),
          Audit.release_tenant_fingerprint_fragment(repo, tenant_id),
          Outbox.release_tenant_fingerprint_fragment(repo, tenant_id),
          AudioCalls.release_tenant_fingerprint_fragment(repo, tenant_id)
        ]

        build(tenant_id, merge_fragments(fragments))
    end
  end

  def format(%{
        version: 1,
        tenant_present: tenant_present,
        counts: counts,
        fingerprint_sha256: fingerprint
      })
      when is_boolean(tenant_present) and is_map(counts) and is_binary(fingerprint) do
    count_fields =
      Enum.map_join(@categories, " ", fn category ->
        "#{category}=#{Map.fetch!(counts, category)}"
      end)

    "K_COMMS_INSTANT_ROOM_TENANT_FINGERPRINT_V1 " <>
      "tenant_present=#{tenant_present} #{count_fields} " <>
      "fingerprint_sha256=#{fingerprint}"
  end

  defp load_app do
    Application.load(@app)
  end

  defp fingerprint_error(:one_shot_runtime_required),
    do: "one_shot_runtime_required"

  defp fingerprint_error(:instant_room_fingerprint_confirmation_required),
    do: "K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION is invalid"

  defp fingerprint_error(:instant_room_tenant_slug_invalid),
    do: "INSTANT_ROOM_TENANT_SLUG is not a configured lowercase tenant slug"

  defp merge_fragments(fragments) when is_list(fragments) do
    identities_by_category =
      Enum.reduce(fragments, %{}, fn fragment, acc ->
        Enum.reduce(fragment, acc, fn
          {category, identities}, inner_acc
          when category in @categories and is_list(identities) ->
            if Map.has_key?(inner_acc, category) or
                 not Enum.all?(identities, &is_binary/1) do
              raise "instant-room tenant fingerprint failed: invalid owner fragment"
            end

            Map.put(inner_acc, category, identities)

          _invalid_entry, _inner_acc ->
            raise "instant-room tenant fingerprint failed: invalid owner fragment"
        end)
      end)

    if Map.keys(identities_by_category) |> MapSet.new() ==
         MapSet.new(@categories) do
      identities_by_category
    else
      raise "instant-room tenant fingerprint failed: incomplete owner fragments"
    end
  end

  defp build(tenant_id, identities_by_category) when is_map(identities_by_category) do
    counts =
      Map.new(@categories, fn category ->
        identities =
          identities_by_category
          |> Map.get(category, [])
          |> Enum.sort()

        {category, length(identities)}
      end)

    canonical =
      [
        "version=1",
        "tenant=#{tenant_id || "absent"}"
        | Enum.map(@categories, fn category ->
            identities =
              identities_by_category
              |> Map.get(category, [])
              |> Enum.sort()

            "#{category}=#{Enum.join(identities, ",")}"
          end)
      ]
      |> Enum.join("\n")

    %{
      version: 1,
      tenant_present: not is_nil(tenant_id),
      counts: counts,
      fingerprint_sha256:
        canonical
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    }
  end
end
