defmodule CommsCore.Accounts.DirectoryTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.Accounts
  alias CommsCore.Accounts.DirectoryPersonView
  alias CommsTestSupport.Fixtures

  @moduletag :integration

  test "member directory is cursor-stable, searchable, and privacy minimal" do
    account = Fixtures.account_fixture(%{display_name: "Excluded Caller"})
    alpha = Fixtures.user_fixture(account, %{display_name: "Alpha Person"}).user
    bravo = Fixtures.user_fixture(account, %{display_name: "Bravo Person"}).user
    charlie = Fixtures.user_fixture(account, %{display_name: "Charlie Person"}).user

    Fixtures.user_fixture(account, %{display_name: "Aardvark Suspended", status: :suspended})

    Fixtures.user_fixture(account, %{
      display_name: "Aardvark Service",
      account_type: :service
    })

    foreign_account = Fixtures.account_fixture(%{display_name: "Aardvark Foreign"})
    subject = Fixtures.subject(account)

    assert {:ok, first_page} = Accounts.list_directory_views(%{limit: 2}, subject)
    assert Enum.map(first_page.people, & &1.id) == [alpha.id, bravo.id]
    assert is_binary(first_page.next_cursor)

    assert Enum.all?(first_page.people, fn person ->
             match?(%DirectoryPersonView{}, person) and
               Map.keys(Map.from_struct(person)) |> Enum.sort() == [:display_name, :id]
           end)

    assert {:ok, second_page} =
             Accounts.list_directory_views(
               %{limit: "2", cursor: first_page.next_cursor},
               subject
             )

    assert Enum.map(second_page.people, & &1.id) == [charlie.id]
    assert second_page.next_cursor == nil

    listed_ids = Enum.map(first_page.people ++ second_page.people, & &1.id)
    refute account.user.id in listed_ids
    refute foreign_account.user.id in listed_ids

    assert {:ok, %{people: [%DirectoryPersonView{id: id}], next_cursor: nil}} =
             Accounts.list_directory_views(%{"q" => "CHARLIE", "limit" => 999}, subject)

    assert id == charlie.id

    assert {:error, :invalid_cursor} =
             Accounts.list_directory_views(%{cursor: "not-an-opaque-cursor"}, subject)

    assert {:error, :invalid_search_query} =
             Accounts.list_directory_views(%{q: String.duplicate("x", 121)}, subject)

    assert {:error, :forbidden} =
             Accounts.list_directory_views(
               %{},
               Map.put(subject, :session_id, Ecto.UUID.generate())
             )
  end
end
