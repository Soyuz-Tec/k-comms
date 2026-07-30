defmodule CommsCore.Conversations.GuestAccess.RedemptionConcurrencyTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Conversations, Repo}
  alias CommsCore.Conversations.{GuestAdmission, GuestLink}
  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation
  @moduletag :guest
  @moduletag :concurrency

  test "max-use redemption remains exact under concurrency" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, %{guest_link: link, token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600, max_uses: 1},
               subject
             )

    results =
      1..6
      |> Task.async_stream(
        fn number ->
          Conversations.redeem_guest_link(
            token,
            guest_attrs("Concurrent Guest #{number}")
          )
        end,
        max_concurrency: 6,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, :guest_link_unavailable}, &1)
           ) == 5

    assert Repo.get!(GuestLink, link.id).use_count == 1

    assert Repo.aggregate(
             from(admission in GuestAdmission,
               where: admission.guest_link_id == ^link.id
             ),
             :count
           ) == 1
  end

  defp guest_attrs(display_name) do
    %{
      display_name: display_name,
      device: %{name: "Guest browser", platform: "test"},
      request_id: "guest-access-test"
    }
  end
end
