defmodule CommsCore.Conversations.GuestAccessTest do
  use CommsCore.DataCase, async: false

  import Ecto.Query

  alias CommsCore.{Accounts, Conversations, Messaging, Repo}

  alias CommsCore.Audit.AuditEvent

  alias CommsCore.Conversations.{
    GuestAdmission,
    GuestLink,
    GuestLinkPreviewView,
    GuestLinkView,
    Membership
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

  test "expired links are indistinguishable from malformed links" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok,
            %{
              guest_link: link,
              token: token,
              conversion_verification_code: nil
            }} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 900},
               subject
             )

    inserted_at = DateTime.utc_now() |> DateTime.add(-3_600, :second)
    expired_at = DateTime.utc_now() |> DateTime.add(-1, :second)

    from(record in GuestLink, where: record.id == ^link.id)
    |> Repo.update_all(set: [inserted_at: inserted_at, expires_at: expired_at])

    assert {:error, :guest_link_unavailable} =
             Conversations.preview_guest_link(token)

    assert {:error, :guest_link_unavailable} =
             Conversations.redeem_guest_link(token, guest_attrs("Expired Guest"))

    assert {:error, :guest_link_unavailable} =
             Conversations.preview_guest_link("not-a-token")
  end

  test "preauthorized conversion preserves membership and excludes it from link revocation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.step_up(account)
    conversion_email = "converted-guest@example.test"

    assert {:ok,
            %{
              guest_link: link,
              token: token,
              conversion_verification_code: verification_code
            }} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{
                 expires_in_seconds: 3_600,
                 max_uses: 1,
                 conversion_email: conversion_email
               },
               subject
             )

    assert link.conversion_enabled
    assert link.email_hint == "c***@example.test"
    assert byte_size(verification_code) == 43

    assert {:ok, verification_secret} =
             Base.url_decode64(verification_code, padding: false)

    assert byte_size(verification_secret) == 32
    refute verification_code == token

    stored_link = Repo.get!(GuestLink, link.id)

    assert stored_link.conversion_verification_digest ==
             conversion_verification_digest(verification_secret, stored_link)

    refute GuestLink.changeset(stored_link, %{conversion_verification_digest: nil}).valid?
    refute :erlang.term_to_binary(stored_link) =~ verification_code

    creation_audit =
      Repo.get_by!(AuditEvent,
        action: "conversation.guest_link.created",
        resource_id: link.id
      )

    refute inspect(creation_audit.metadata) =~ verification_code

    assert {:ok, [listed_link]} =
             Conversations.list_guest_link_views(account.conversation.id, subject)

    refute inspect(listed_link) =~ verification_code

    assert {:ok, preview} = Conversations.preview_guest_link(token)
    assert preview.conversion_enabled
    assert preview.email_hint == "c***@example.test"
    refute inspect(preview) =~ conversion_email
    refute inspect(preview) =~ verification_code

    assert {:ok, redemption} =
             Conversations.redeem_guest_link(token, guest_attrs("Convertible Guest"))

    assert redemption.capabilities.conversion_enabled
    assert redemption.capabilities.email_hint == "c***@example.test"
    refute inspect(redemption) =~ verification_code

    guest_subject = guest_subject(redemption)

    assert {:error, :guest_account_conversion_email_mismatch} =
             Conversations.convert_guest_account(
               %{
                 email: "someone-else@example.test",
                 verification_code: verification_code,
                 password: "converted-guest-password-123",
                 device: %{name: "Account browser", platform: "test"}
               },
               guest_subject
             )

    assert {:error, :guest_account_conversion_verification_failed} =
             Conversations.convert_guest_account(
               %{
                 email: conversion_email,
                 password: "converted-guest-password-123",
                 device: %{name: "Account browser", platform: "test"}
               },
               guest_subject
             )

    assert {:error, :guest_account_conversion_verification_failed} =
             Conversations.convert_guest_account(
               %{
                 email: conversion_email,
                 verification_code:
                   Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
                 password: "converted-guest-password-123",
                 device: %{name: "Account browser", platform: "test"}
               },
               guest_subject
             )

    assert {:ok, converted} =
             Conversations.convert_guest_account(
               %{
                 email: String.upcase(conversion_email),
                 verification_code: verification_code,
                 password: "converted-guest-password-123",
                 device: %{name: "Account browser", platform: "test"}
               },
               guest_subject
             )

    assert converted.authentication.user.id == redemption.authentication.user.id
    assert converted.authentication.user.account_type == :human
    assert converted.conversation.id == account.conversation.id

    admission = Repo.get!(GuestAdmission, redemption.admission.id)
    assert %DateTime{} = admission.converted_at

    assert {:error, :forbidden} =
             Conversations.convert_guest_account(
               %{
                 email: conversion_email,
                 verification_code: verification_code,
                 password: "converted-guest-password-123"
               },
               guest_subject
             )

    assert %Membership{left_at: nil} =
             Repo.get_by!(Membership,
               tenant_id: account.tenant.id,
               conversation_id: account.conversation.id,
               user_id: redemption.authentication.user.id
             )

    assert {:ok, %{guest_link: _revoked_link, revoked_session_ids: []}} =
             Conversations.revoke_guest_link_view(
               account.conversation.id,
               link.id,
               subject
             )

    assert %Membership{left_at: nil} =
             Repo.get_by!(Membership,
               tenant_id: account.tenant.id,
               conversation_id: account.conversation.id,
               user_id: redemption.authentication.user.id
             )
  end

  test "communication links stay conversion-disabled and conversion preauthorization is privileged" do
    account = Fixtures.account_fixture()
    owner_subject = Fixtures.subject(account)

    assert {:ok,
            %{
              guest_link: ordinary_link,
              token: token,
              conversion_verification_code: nil
            }} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600, max_uses: 2},
               owner_subject
             )

    refute ordinary_link.conversion_enabled
    assert is_nil(ordinary_link.email_hint)

    assert {:ok, %{conversion_enabled: false, email_hint: nil}} =
             Conversations.preview_guest_link(token)

    assert {:ok, redemption} =
             Conversations.redeem_guest_link(token, guest_attrs("Communication Guest"))

    refute redemption.capabilities.self_service_conversion

    assert {:ok, %{capabilities: %{self_service_conversion: false}}} =
             Conversations.guest_scope_for_session(redemption.authentication.session_id)

    assert {:error, :guest_account_conversion_not_enabled} =
             Conversations.convert_guest_account(
               %{
                 email: "communication-guest@example.test",
                 password: "communication-guest-password-123"
               },
               guest_subject(redemption)
             )

    assert {:error, :step_up_required} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{
                 expires_in_seconds: 3_600,
                 max_uses: 1,
                 conversion_email: "preauthorized@example.test"
               },
               owner_subject
             )

    assert {:error, :guest_account_conversion_requires_single_use} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{
                 expires_in_seconds: 3_600,
                 max_uses: 2,
                 conversion_email: "preauthorized@example.test"
               },
               Fixtures.step_up(account)
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

  test "database ownership rejects a guest admission linked to another conversation" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, other_conversation} =
             Conversations.create(
               %{kind: :group, title: "Other guest scope"},
               subject
             )

    assert {:ok, %{token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600, max_uses: 1},
               subject
             )

    assert {:ok, redemption} =
             Conversations.redeem_guest_link(token, guest_attrs("Scoped Guest"))

    admission = Repo.get!(GuestAdmission, redemption.admission.id)

    assert_raise Ecto.ConstraintError,
                 ~r/conversation_guest_admissions_tenant_link_fk/,
                 fn ->
                   Repo.transaction(fn ->
                     admission
                     |> Ecto.Changeset.change(%{conversation_id: other_conversation.id})
                     |> Repo.update!()
                   end)
                 end
  end

  test "guest history starts at admission and omits earlier messages" do
    account = Fixtures.account_fixture()
    subject = Fixtures.subject(account)

    assert {:ok, before_admission} =
             Messaging.accept_message(
               owner_message_attrs(account, "guest-history-before", "Before admission"),
               subject
             )

    assert {:ok, %{token: token}} =
             Conversations.create_guest_link_view(
               account.conversation.id,
               %{expires_in_seconds: 3_600},
               subject
             )

    assert {:ok, redemption} =
             Conversations.redeem_guest_link(token, guest_attrs("History Guest"))

    assert redemption.admission.history_from_sequence ==
             before_admission.conversation_sequence + 1

    assert {:ok, after_admission} =
             Messaging.accept_message(
               owner_message_attrs(account, "guest-history-after", "After admission"),
               subject
             )

    guest_subject = guest_subject(redemption)

    assert {:ok, history} =
             Messaging.list_history(account.conversation.id, guest_subject)

    assert Enum.map(history, & &1.id) == [after_admission.id]
    refute Enum.any?(history, &(&1.id == before_admission.id))

    assert {:error, :forbidden} =
             Messaging.list_history(
               account.conversation.id,
               Map.delete(guest_subject, :guest_history_from_sequence)
             )
  end

  defp guest_attrs(display_name) do
    %{
      display_name: display_name,
      device: %{name: "Guest browser", platform: "test"},
      request_id: "guest-access-test"
    }
  end

  defp guest_subject(redemption) do
    assert {:ok, context} =
             Accounts.guest_access_context(
               redemption.authentication.session_id,
               "guest-access-test"
             )

    Map.merge(context.subject, %{
      guest_admission_id: redemption.admission.id,
      guest_conversation_id: redemption.conversation.id,
      guest_history_from_sequence: redemption.admission.history_from_sequence
    })
  end

  defp owner_message_attrs(account, client_message_id, body) do
    %{
      tenant_id: account.tenant.id,
      conversation_id: account.conversation.id,
      sender_user_id: account.user.id,
      sender_device_id: account.device.id,
      client_message_id: client_message_id,
      body: body
    }
  end

  defp conversion_verification_digest(secret, link) do
    :crypto.hash(:sha256, [
      "k-comms:guest-conversion-verification:v1",
      <<0>>,
      link.tenant_id,
      <<0>>,
      link.conversation_id,
      <<0>>,
      link.id,
      <<0>>,
      link.conversion_email,
      <<0>>,
      secret
    ])
  end
end
