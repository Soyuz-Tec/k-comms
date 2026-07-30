defmodule CommsCore.Conversations.GuestAccess.ConversionTest do
  use CommsCore.DataCase, async: false

  alias CommsCore.{Accounts, Conversations, Repo}
  alias CommsCore.Audit.AuditEvent

  alias CommsCore.Conversations.{
    GuestAdmission,
    GuestLink,
    Membership
  }

  alias CommsTestSupport.Fixtures

  @moduletag :integration
  @moduletag :conversation
  @moduletag :guest

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
