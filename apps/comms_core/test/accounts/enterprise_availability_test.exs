defmodule CommsCore.Accounts.EnterpriseAvailabilityTest do
  use CommsCore.DataCase, async: false
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Accounts.{Availability, User}
  alias CommsTestSupport.Fixtures

  test "second, browser millisecond and six-digit deadlines preserve their instants in both availability fields" do
    owner = Fixtures.account_fixture()
    subject = Fixtures.subject(owner)
    future = DateTime.add(DateTime.utc_now(), 3_600, :second)

    for {microsecond, precision} <- [{0, 0}, {588_000, 3}, {588_321, 6}] do
      expected_presence = %{future | microsecond: {microsecond, precision}}
      expected_dnd = DateTime.add(expected_presence, 1_800, :second)

      offset_dnd =
        (expected_dnd
         |> DateTime.to_naive()
         |> NaiveDateTime.add(19_800, :second)
         |> NaiveDateTime.to_iso8601()) <> "+05:30"

      assert {:ok, availability} =
               Accounts.update_availability(
                 %{
                   "presence_state" => "busy",
                   "presence_expires_at" => DateTime.to_iso8601(expected_presence),
                   "dnd_until" => offset_dnd,
                   "dnd_schedule" => %{}
                 },
                 subject
               )

      assert DateTime.compare(availability.presence_expires_at, expected_presence) == :eq
      assert DateTime.compare(availability.dnd_until, expected_dnd) == :eq
      assert availability.presence_expires_at.microsecond == {microsecond, 6}
      assert availability.dnd_until.microsecond == {microsecond, 6}

      stored = Repo.get!(User, owner.user.id)
      assert DateTime.compare(stored.presence_expires_at, expected_presence) == :eq
      assert DateTime.compare(stored.dnd_until, expected_dnd) == :eq

      assert {:ok, %{allowed: false, retry_at: retry_at}} =
               Accounts.delivery_availability(owner.tenant.id, owner.user.id, :call)

      assert DateTime.compare(retry_at, expected_dnd) == :eq
    end
  end

  test "timestamp normalization retains timezone and bounded-deadline validation" do
    owner = Fixtures.account_fixture()
    subject = Fixtures.subject(owner)
    future = DateTime.add(DateTime.utc_now(), 3_600, :second)

    for field <- ["presence_expires_at", "dnd_until"],
        invalid <- [
          future |> DateTime.to_naive() |> NaiveDateTime.to_iso8601(),
          DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601(),
          DateTime.utc_now() |> DateTime.add(691_200, :second) |> DateTime.to_iso8601()
        ] do
      assert {:error, :invalid_availability} =
               Accounts.update_availability(%{field => invalid}, subject)
    end

    stored = Repo.get!(User, owner.user.id)
    refute stored.presence_expires_at
    refute stored.dnd_until
  end

  test "DND affects outbound channels but keeps inbox delivery and is tenant isolated" do
    owner = Fixtures.account_fixture()
    other = Fixtures.account_fixture()

    {:ok, state} =
      Accounts.update_availability(%{"presence_state" => "dnd"}, Fixtures.subject(owner))

    assert state.dnd_active

    for channel <- [:email, :push, :call] do
      assert {:ok, %{allowed: false, retry_at: nil}} =
               Accounts.delivery_availability(owner.tenant.id, owner.user.id, channel)
    end

    assert {:ok, %{allowed: true}} =
             Accounts.delivery_availability(owner.tenant.id, owner.user.id, :in_app)

    assert {:error, :not_found} =
             Accounts.delivery_availability(other.tenant.id, owner.user.id, :call)

    assert {:error, :forbidden} =
             Accounts.update_availability(
               %{},
               Map.put(Fixtures.subject(owner), :tenant_id, other.tenant.id)
             )
  end

  test "overnight weekly schedules use the user's IANA timezone and expire exactly" do
    owner = Fixtures.account_fixture()

    user =
      Repo.update!(
        Ecto.Changeset.change(owner.user,
          timezone: "America/New_York",
          dnd_schedule: %{"days" => [1], "start" => "22:00", "end" => "08:00"}
        )
      )

    # Monday night extends into Tuesday, with the correct daylight offset.
    during = Availability.view(user, ~U[2026-10-06 03:00:00Z])
    assert during.dnd_active
    assert DateTime.compare(during.retry_at, ~U[2026-10-06 12:00:00Z]) == :eq
    refute Availability.view(user, ~U[2026-10-06 12:00:00Z]).dnd_active

    assert {:error, :invalid_availability} =
             Accounts.update_availability(
               %{"dnd_schedule" => %{"days" => [8], "start" => "00:00", "end" => "08:00"}},
               Fixtures.subject(owner)
             )
  end

  test "weekly DND covers both repeated fall hours and moves nonexistent spring starts forward" do
    owner = Fixtures.account_fixture()

    user = %{
      owner.user
      | timezone: "America/New_York",
        dnd_schedule: %{"days" => [7], "start" => "01:15", "end" => "01:45"}
    }

    for now <- [~U[2026-11-01 05:30:00Z], ~U[2026-11-01 06:30:00Z]] do
      state = Availability.view(user, now)
      assert state.dnd_active
      assert DateTime.compare(state.retry_at, ~U[2026-11-01 06:45:00Z]) == :eq
    end

    refute Availability.view(user, ~U[2026-11-01 06:45:00Z]).dnd_active
    user = %{user | dnd_schedule: %{"days" => [7], "start" => "02:15", "end" => "03:30"}}
    refute Availability.view(user, ~U[2026-03-08 06:59:00Z]).dnd_active
    assert Availability.view(user, ~U[2026-03-08 07:01:00Z]).dnd_active
    refute Availability.view(user, ~U[2026-03-08 07:30:00Z]).dnd_active
  end

  test "profile keeps recovery identity immutable and rejects tracking avatars and invalid timezones" do
    owner = Fixtures.account_fixture()
    subject = Fixtures.subject(owner)

    assert {:error, :email_change_requires_verification} =
             Accounts.update_profile_view(
               %{
                 "display_name" => "Changed",
                 "email" => "attacker@example.test",
                 "timezone" => "Europe/London"
               },
               subject
             )

    assert Repo.get!(User, owner.user.id).display_name == owner.user.display_name

    assert {:error, _} =
             Accounts.update_profile_view(
               %{"display_name" => "Changed", "avatar_url" => "https://tracker.test/person.png"},
               subject
             )

    assert {:error, _} =
             Accounts.update_profile_view(
               %{"display_name" => "Changed", "timezone" => "Invalid/Timezone"},
               subject
             )

    assert {:ok, %{timezone: "Asia/Kolkata"}} =
             Accounts.update_profile_view(
               %{"display_name" => "Changed", "timezone" => "Asia/Kolkata"},
               subject
             )
  end
end
