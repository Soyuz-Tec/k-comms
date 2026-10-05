defmodule CommsWeb.FallbackControllerTest do
  use CommsWeb.ConnCase, async: true

  alias CommsWeb.FallbackController

  test "filters conversion verification secrets from request logging" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "verification_code" => "guest-conversion-code",
        "conversion_verification_code" => "creator-only-code",
        "password" => "guest-password",
        "token" => "guest-link-token",
        "display_name" => "Visible Guest"
      })

    assert filtered["verification_code"] == "[FILTERED]"
    assert filtered["conversion_verification_code"] == "[FILTERED]"
    assert filtered["password"] == "[FILTERED]"
    assert filtered["token"] == "[FILTERED]"
    assert filtered["display_name"] == "Visible Guest"
  end

  test "maps expired call authority to a non-sensitive forbidden response" do
    response =
      build_conn()
      |> FallbackController.call({:error, :call_authorization_expired})
      |> json_response(403)

    assert response == %{
             "error" => %{
               "code" => "call_authorization_expired",
               "detail" => "Call access is no longer authorized"
             }
           }
  end

  test "maps guest account conversion policy failures without disclosing the authorized email" do
    disabled =
      build_conn()
      |> FallbackController.call({:error, :guest_account_conversion_not_enabled})
      |> json_response(403)

    forbidden =
      build_conn()
      |> FallbackController.call({:error, :guest_account_conversion_forbidden})
      |> json_response(403)

    mismatch =
      build_conn()
      |> FallbackController.call({:error, :guest_account_conversion_email_mismatch})
      |> json_response(403)

    verification_failed =
      build_conn()
      |> FallbackController.call({:error, :guest_account_conversion_verification_failed})
      |> json_response(403)

    invalid_email =
      build_conn()
      |> FallbackController.call({:error, :invalid_guest_conversion_email})
      |> json_response(422)

    invalid_use_count =
      build_conn()
      |> FallbackController.call({:error, :guest_account_conversion_requires_single_use})
      |> json_response(422)

    assert disabled["error"]["code"] == "guest_account_conversion_not_enabled"

    assert forbidden == %{
             "error" => %{
               "code" => "guest_account_conversion_forbidden",
               "detail" => "Account creation is not permitted for this guest link"
             }
           }

    assert mismatch["error"]["code"] == "guest_account_conversion_email_mismatch"

    assert verification_failed == %{
             "error" => %{
               "code" => "guest_account_conversion_verification_failed",
               "detail" => "Account conversion verification failed"
             }
           }

    assert invalid_email == %{
             "error" => %{
               "code" => "invalid_guest_conversion_email",
               "detail" => "The account conversion email is invalid"
             }
           }

    assert invalid_use_count["error"]["code"] == "guest_account_conversion_requires_single_use"

    refute inspect([
             disabled,
             forbidden,
             mismatch,
             verification_failed,
             invalid_email,
             invalid_use_count
           ]) =~ "@"
  end

  test "keeps expected telephone policy and provider failures out of internal server errors" do
    failures = [
      {422, :invalid_telephony_command},
      {422, :invalid_telephony_route},
      {422, :invalid_telephony_mailbox},
      {422, :invalid_voicemail_limit},
      {422, :invalid_voicemail_cursor},
      {422, :invalid_voicemail_media},
      {409, :telephony_control_conflict},
      {409, :recipient_unavailable},
      {409, :voicemail_capture_cancelled},
      {422, :voicemail_storage_identity_invalid},
      {409, :voicemail_provider_identity_invalid},
      {409, :voicemail_legal_hold},
      {409, :voicemail_not_deletable},
      {409, :voicemail_already_deleted},
      {409, :telephony_mailbox_full},
      {429, :telephony_control_limit},
      {503, :telephony_control_unsupported},
      {503, :telephony_control_unavailable},
      {409, :telephony_mailbox_unavailable},
      {503, :telephony_voicemail_unavailable},
      {503, :voicemail_storage_unavailable},
      {503, :voicemail_provider_unavailable},
      {503, :voicemail_protection_unavailable},
      {503, :voicemail_source_deletion_pending}
    ]

    for {status, reason} <- failures do
      response =
        build_conn()
        |> FallbackController.call({:error, reason})
        |> json_response(status)

      assert response["error"]["code"] == Atom.to_string(reason)
      refute response["error"]["detail"] =~ ~r/recordings\/|https?:\/\/|kc_vm_|password/i
    end
  end
end
