defmodule CommsCore.Conversations.GuestAccess.LinkManagementTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Conversations, Repo}

  alias CommsCore.Conversations.{
    GuestLink,
    GuestLinkPreviewView,
    GuestLinkView
  }

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation
  @moduletag :guest

  test "stores only a digest and returns the raw token once" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok,
            %{
              guest_link: %GuestLinkView{} = view,
              token: token,
              conversion_verification_code: nil
            }} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600, max_uses: 3},
               subject
             )

    assert [link_id, encoded_secret] = String.split(token, ".", parts: 2)
    assert link_id == view.id
    assert {:ok, secret} = Base.url_decode64(encoded_secret, padding: false)
    assert byte_size(secret) == 32
    assert byte_size(token) == 80

    stored = Repo.get!(GuestLink, view.id)
    assert stored.token_digest == :crypto.hash(:sha256, secret)
    assert is_nil(stored.conversion_verification_digest)
    refute :erlang.term_to_binary(stored) =~ token

    assert {:ok, [listed]} =
             Conversations.list_guest_link_views(account.conversation.id, subject)

    assert listed.id == view.id
    refute Map.has_key?(Map.from_struct(listed), :token)

    assert {:ok,
            %GuestLinkPreviewView{
              room_title: "General",
              expires_at: expires_at,
              conversion_enabled: false,
              email_hint: nil
            } = preview} = Conversations.preview_guest_link(token)

    assert expires_at == view.expires_at

    assert Map.keys(Map.from_struct(preview)) |> Enum.sort() ==
             [:conversion_enabled, :email_hint, :expires_at, :room_title]

    tampered =
      link_id <>
        "." <>
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:error, :guest_link_unavailable} =
             Conversations.preview_guest_link(tampered)
  end

  test "direct conversations reject guest links and foreign managers fail closed" do
    account = Fixtures.account_fixture()
    member = Fixtures.user_fixture(account)
    subject = Fixtures.subject(account)

    assert {:ok, direct} =
             Conversations.create(
               %{kind: :direct, member_ids: [member.user.id]},
               subject
             )

    assert {:error, :guest_links_not_supported} =
             Conversations.create_guest_link_view(
               direct.id,
               %{expires_in_seconds: 3_600},
               subject
             )

    assert {:ok, %{guest_link: link}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600},
               subject
             )

    foreign = Fixtures.account_fixture()
    foreign_subject = Fixtures.subject(foreign)

    assert {:error, :forbidden} =
             Conversations.list_guest_link_views(
               account.conversation.id,
               foreign_subject
             )

    assert {:error, :forbidden} =
             Conversations.revoke_guest_link_view(
               account.conversation.id,
               link.id,
               foreign_subject
             )
  end

  test "conversation moderators retain communication-only link authority" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)
    suffix = System.unique_integer([:positive, :monotonic])
    email = "guest-link-moderator-#{suffix}@example.test"
    password = "guest-link-moderator-password-#{suffix}"

    assert {:ok, moderator} =
             Accounts.create_user(
               %{
                 display_name: "Guest Link Moderator",
                 email: email,
                 password: password,
                 role: :member
               },
               Fixtures.step_up(account)
             )

    assert {:ok, _membership} =
             Conversations.add_member(
               account.conversation.id,
               moderator.id,
               :moderator,
               owner_subject
             )

    assert {:ok, login} =
             Accounts.authenticate_view(account.tenant.slug, email, password, %{
               name: "Moderator browser",
               platform: "test"
             })

    assert {:ok, moderator_context} =
             Accounts.access_context(login.session_id, "guest-link-moderator-test")

    moderator_subject = moderator_context.subject

    assert {:ok, %{guest_link: %{conversion_enabled: false}, token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600, max_uses: 2},
               moderator_subject
             )

    assert {:ok, _preview} = Conversations.preview_guest_link(token)

    assert {:error, :guest_account_conversion_forbidden} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{
                 expires_in_seconds: 3_600,
                 max_uses: 1,
                 conversion_email: "moderator-target@example.test"
               },
               moderator_subject
             )
  end
end
