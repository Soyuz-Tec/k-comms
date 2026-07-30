defmodule CommsCore.ReleaseInstantRoomFingerprintTest do
  use CommsCore.DataCase, async: true

  alias CommsCore.Release
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :release

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

  defmodule ReadOnlyRepo do
    def one(%Ecto.Query{}), do: "tenant-internal-id"

    def all(%Ecto.Query{from: %{source: {table, _schema}}}) do
      [
        Map.fetch!(
          %{
            "users" => "user-internal-id",
            "sessions" => "session-internal-id",
            "devices" => "device-internal-id",
            "conversations" => "conversation-internal-id",
            "conversation_memberships" => "membership-internal-id",
            "messages" => "message-internal-id",
            "conversation_guest_links" => "guest-link-internal-id",
            "conversation_guest_admissions" => "guest-admission-internal-id",
            "conversation_ephemeral_rooms" => "room-internal-id",
            "conversation_ephemeral_presence_leases" => "lease-internal-id",
            "conversation_ephemeral_join_receipts" => "receipt-internal-id",
            "audit_events" => "audit-internal-id",
            "outbox_events" => "outbox-internal-id",
            "audio_calls" => "call-internal-id",
            "audio_call_participants" => "participant-internal-id"
          },
          table
        )
      ]
    end
  end

  test "environment requires the one-shot purpose, dedicated confirmation, and fixed slug" do
    environment = %{
      "K_COMMS_RUNTIME_PURPOSE" => "one_shot",
      "K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION" =>
        "fixed-instant-room-tenant-fingerprint-v1",
      "INSTANT_ROOM_TENANT_SLUG" => "k-comms-development"
    }

    assert {:ok, %{tenant_slug: "k-comms-development"}} =
             Release.validate_instant_room_fingerprint_environment(&Map.get(environment, &1))

    for {name, value, expected_error} <- [
          {"K_COMMS_RUNTIME_PURPOSE", "application", :one_shot_runtime_required},
          {"K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION", "wrong",
           :instant_room_fingerprint_confirmation_required},
          {"INSTANT_ROOM_TENANT_SLUG", "Qualification Tenant", :instant_room_tenant_slug_invalid},
          {"INSTANT_ROOM_TENANT_SLUG", "", :instant_room_tenant_slug_invalid}
        ] do
      assert {:error, ^expected_error} =
               Release.validate_instant_room_fingerprint_environment(
                 &(environment
                   |> Map.put(name, value)
                   |> Map.get(&1))
               )
    end
  end

  test "read-only graph query covers every required category and redacts identities" do
    assert Release.instant_room_tenant_fingerprint_categories() == @categories

    report =
      Release.instant_room_tenant_fingerprint(
        ReadOnlyRepo,
        "k-comms-development"
      )

    assert report.version == 1
    assert report.tenant_present
    assert Map.keys(report.counts) |> Enum.sort() == Enum.sort(@categories)
    assert Enum.all?(report.counts, fn {_category, count} -> count == 1 end)
    assert report.fingerprint_sha256 =~ ~r/\A[0-9a-f]{64}\z/

    output = Release.format_instant_room_tenant_fingerprint(report)

    assert output =~
             ~r/\AK_COMMS_INSTANT_ROOM_TENANT_FINGERPRINT_V1 tenant_present=true /

    assert output =~ "ephemeral_join_receipts=1"
    assert output =~ "call_participants=1"
    assert output =~ ~r/ fingerprint_sha256=[0-9a-f]{64}\z/

    for forbidden <- [
          "k-comms-development",
          "tenant-internal-id",
          "user-internal-id",
          "message-internal-id",
          "call-internal-id"
        ] do
      refute output =~ forbidden
    end
  end

  test "fingerprint is stable, tenant-isolated, and changes with fixed-tenant residue" do
    suffix = System.unique_integer([:positive, :monotonic])

    fixed =
      Fixtures.account_fixture(%{
        tenant_slug: "fixed-fingerprint-#{suffix}"
      })

    other = Fixtures.account_fixture()

    before =
      Release.instant_room_tenant_fingerprint(
        CommsCore.Repo,
        fixed.tenant.slug
      )

    assert before ==
             Release.instant_room_tenant_fingerprint(
               CommsCore.Repo,
               fixed.tenant.slug
             )

    assert before.tenant_present
    assert before.counts.users == 1
    assert before.counts.sessions == 1
    assert before.counts.devices == 1
    assert before.counts.conversations == 1
    assert before.counts.memberships == 1

    Fixtures.user_fixture(other)

    assert before ==
             Release.instant_room_tenant_fingerprint(
               CommsCore.Repo,
               fixed.tenant.slug
             )

    Fixtures.user_fixture(fixed)

    after_residue =
      Release.instant_room_tenant_fingerprint(
        CommsCore.Repo,
        fixed.tenant.slug
      )

    assert after_residue.counts.users == before.counts.users + 1
    refute after_residue.fingerprint_sha256 == before.fingerprint_sha256

    output = Release.format_instant_room_tenant_fingerprint(after_residue)

    refute output =~ fixed.tenant.slug
    refute output =~ fixed.tenant.id
    refute output =~ fixed.user.id
    refute output =~ fixed.user.email
  end

  test "an absent configured tenant has deterministic zero counts" do
    first =
      Release.instant_room_tenant_fingerprint(
        CommsCore.Repo,
        "absent-fixed-instant-room"
      )

    second =
      Release.instant_room_tenant_fingerprint(
        CommsCore.Repo,
        "another-absent-fixed-instant-room"
      )

    refute first.tenant_present
    assert first.counts == Map.new(@categories, &{&1, 0})
    assert first == second
  end
end
